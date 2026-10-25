defmodule Guardian.Web.IngestIdempotencyTest do
  use ExUnit.Case, async: true

  alias Guardian.Web.IngestIdempotency, as: Idempotency

  setup do
    clock = :atomics.new(1, [])
    server = start_server(clock: fn -> :atomics.get(clock, 1) end)
    %{server: server, clock: clock}
  end

  defp start_server(opts) do
    name = :"ingest_idempotency_#{System.unique_integer([:positive])}"
    start_supervised!({Idempotency, Keyword.put(opts, :name, name)}, id: name)
  end

  defp run(server, key, ingest \\ fn -> %{status: 200, results: []} end) do
    Idempotency.run("events", key, {[], nil}, ingest, server)
  end

  defp receipt(failed \\ 0),
    do: {:ok, %{status: 200, duplicate: true, failed_events: failed}}

  test "receipts retain failed outcomes but no event payloads", %{server: server} do
    payload = "private-event-payload"
    key = "private-retry-key"

    result = %{
      status: 200,
      results: [
        %{success: true, event: %{"secret" => payload}},
        %{success: false, error: payload},
      ],
    }

    assert run(server, key, fn -> result end) == {:ok, result}
    assert run(server, key, fn -> flunk("duplicate ran ingestion") end) == receipt(1)
    assert :sys.get_state(server).monitors == %{}
    refute :erlang.term_to_binary(:sys.get_state(server)) =~ payload
    refute inspect(:sys.get_status(server)) =~ key
  end

  test "atomic claims prevent concurrent duplicate work without blocking unrelated keys", %{
    server: server,
  } do
    test_pid = self()

    {owner, owner_ref} =
      spawn_monitor(fn ->
        result =
          run(server, "same", fn ->
            send(test_pid, :ingesting)
            receive do: (:finish -> %{status: 200, results: []})
          end)

        send(test_pid, {:original, result})
      end)

    on_exit(fn -> Process.exit(owner, :kill) end)
    assert_receive :ingesting

    assert {:error, 409, changed} =
             Idempotency.run(
               "events",
               "same",
               {[1], nil},
               fn -> flunk("changed request") end,
               server
             )

    assert changed =~ "different events"

    for _ <- 1..12 do
      spawn(fn ->
        send(test_pid, {:duplicate, run(server, "same", fn -> flunk("duplicate") end)})
      end)
    end

    for _ <- 1..12 do
      assert_receive {:duplicate, {:error, 409, message}}
      assert message =~ "in flight"
    end

    assert run(server, "unrelated") == {:ok, %{status: 200, results: []}}
    send(owner, :finish)
    assert_receive {:original, {:ok, %{status: 200, results: []}}}
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}
    assert run(server, "same") == receipt()
  end

  test "retained identity strings do not pin a large request binary", %{server: server} do
    body = String.duplicate("x", 1_000_000)
    table = binary_part(body, 0, 64)
    key = binary_part(body, 100, 128)
    assert :binary.referenced_byte_size(key) > byte_size(key)

    assert {:ok, _} =
             Idempotency.run(table, key, {[], nil}, fn -> %{status: 200, results: []} end, server)

    [{kept_table, kept_key}] = Map.keys(:sys.get_state(server).entries)
    assert :binary.referenced_byte_size(kept_table) == byte_size(kept_table)
    assert :binary.referenced_byte_size(kept_key) == byte_size(kept_key)
  end

  test "the full retention period starts at completion and repeats do not refresh it", %{
    server: server,
    clock: clock,
  } do
    test_pid = self()

    owner =
      spawn(fn ->
        run(server, "slow", fn ->
          send(test_pid, :ingesting)
          receive do: (:finish -> %{status: 200, results: []})
        end)

        send(test_pid, :finished)
      end)

    on_exit(fn -> Process.exit(owner, :kill) end)
    assert_receive :ingesting
    :atomics.put(clock, 1, 20_000)
    assert {:error, 409, _} = run(server, "slow")
    send(owner, :finish)
    assert_receive :finished
    :atomics.put(clock, 1, 29_999)
    assert run(server, "slow") == receipt()
    :atomics.put(clock, 1, 30_000)
    assert run(server, "slow") == {:ok, %{status: 200, results: []}}
  end

  test "periodic sweep drops expired entries even without another ingest", %{
    server: server,
    clock: clock,
  } do
    assert {:ok, _} = run(server, "expires")
    :atomics.put(clock, 1, 10_000)
    send(server, :sweep)
    assert :sys.get_state(server).entries == %{}
    assert :gb_trees.is_empty(:sys.get_state(server).completed)
  end

  test "capacity evicts the oldest completed entry", %{clock: clock} do
    server = start_server(max_entries: 2, clock: fn -> :atomics.get(clock, 1) end)
    assert {:ok, _} = run(server, "oldest")
    :atomics.put(clock, 1, 1)
    assert {:ok, _} = run(server, "newer")
    assert {:ok, _} = run(server, "newest")
    assert run(server, "newer") == receipt()
    assert run(server, "newest") == receipt()
    refute Map.has_key?(:sys.get_state(server).entries, {"events", "oldest"})
    assert {:ok, %{results: []}} = run(server, "oldest")
    assert map_size(:sys.get_state(server).entries) == 2
  end

  test "all-pending capacity fails open without evicting a live claim" do
    server = start_server(max_entries: 1)
    token = make_ref()
    digest = :crypto.hash(:sha256, :erlang.term_to_binary({[], nil}, [:deterministic]))
    assert GenServer.call(server, {:claim, {"events", "pending"}, digest, token}) == :claimed

    for _ <- 1..2 do
      assert run(server, "unprotected") == {:ok, %{status: 200, results: []}}
    end

    assert {:error, 409, message} = run(server, "pending")
    assert message =~ "in flight"
    assert map_size(:sys.get_state(server).entries) == 1
  end

  test "caller death retains uncertainty until expiry", %{server: server, clock: clock} do
    test_pid = self()

    {owner, owner_ref} =
      spawn_monitor(fn ->
        run(server, "killed", fn ->
          send(test_pid, :ingesting)
          receive do: (:never -> flunk("should be killed"))
        end)
      end)

    assert_receive :ingesting
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}
    # This test's DOWN does not order the coordinator's DOWN; wait for its transition.
    wait_until_uncertain(server)
    assert {:error, 409, message} = run(server, "killed")
    assert message =~ "may have been stored"
    :atomics.put(clock, 1, 10_000)
    assert {:ok, %{results: []}} = run(server, "killed")
  end

  defp wait_until_uncertain(server, attempts \\ 100) do
    if map_size(:sys.get_state(server).monitors) > 0 do
      assert attempts > 0
      Process.sleep(1)
      wait_until_uncertain(server, attempts - 1)
    end
  end

  test "caught errors, exits and throws mark uncertainty even when caller survives", %{
    server: server,
  } do
    for {key, fail} <- [
          {"raise", fn -> raise "private error" end},
          {"exit", fn -> exit(:private_exit) end},
          {"throw", fn -> throw(:private_throw) end},
        ] do
      try do
        run(server, key, fail)
        flunk("ingest should fail")
      catch
        _kind, _reason -> :ok
      end

      assert {:error, 409, message} = run(server, key)
      assert message =~ "unknown"
    end

    assert Process.alive?(self())
    assert :sys.get_state(server).monitors == %{}
  end

  test "completion requires its token and owner and stale tokens cannot replace a new claim", %{
    server: server,
    clock: clock,
  } do
    identity = {"events", "token"}
    first = make_ref()
    assert GenServer.call(server, {:claim, identity, "digest", first}) == :claimed
    test_pid = self()

    spawn(fn ->
      send(test_pid, {:forged, GenServer.call(server, {:finish, first, {:done, 99}})})
    end)

    assert_receive {:forged, :ok}
    assert :sys.get_state(server).entries[identity].status == :pending
    assert GenServer.call(server, {:finish, first, {:done, 0}}) == :ok
    :atomics.put(clock, 1, 10_000)
    second = make_ref()
    assert GenServer.call(server, {:claim, identity, "digest", second}) == :claimed
    assert GenServer.call(server, {:finish, first, {:done, 99}}) == :ok
    assert :sys.get_state(server).entries[identity].token == second
  end

  test "unavailable coordinator fails open and a restart forgets keys" do
    name = :"idempotency_restart_#{System.unique_integer([:positive])}"
    pid = start_supervised!({Idempotency, name: name}, id: name)
    assert {:ok, %{results: []}} = run(name, "restart")
    assert run(name, "restart") == receipt()
    stop_supervised!(name)
    assert run(name, "restart") == {:ok, %{status: 200, results: []}}
    refute Process.alive?(pid)
    start_supervised!({Idempotency, name: name}, id: name)
    assert {:ok, %{results: []}} = run(name, "restart")
  end

  test "a timed-out claim is cancelled after resume even when its caller lives", %{server: server} do
    :ok = :sys.suspend(server)

    try do
      assert run(server, "late") == {:ok, %{status: 200, results: []}}
    after
      :ok = :sys.resume(server)
    end

    assert :sys.get_state(server).entries == %{}
    assert :sys.get_state(server).monitors == %{}
    assert {:ok, %{results: []}} = run(server, "late")
  end

  test "a timed-out completion still returns the original response", %{server: server} do
    try do
      assert run(server, "finish_late", fn ->
               :ok = :sys.suspend(server)
               %{status: 200, results: []}
             end) == {:ok, %{status: 200, results: []}}
    after
      :ok = :sys.resume(server)
    end

    assert run(server, "finish_late") == receipt()
  end
end
