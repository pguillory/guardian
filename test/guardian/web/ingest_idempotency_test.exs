defmodule Guardian.Web.IngestIdempotencyTest do
  use ExUnit.Case, async: true

  alias Guardian.Web.IngestIdempotency, as: Idempotency

  setup do
    %{server: start_server([])}
  end

  defp start_server(opts) do
    name = :"ingest_idempotency_#{System.unique_integer([:positive])}"
    start_supervised!({Idempotency, Keyword.put(opts, :name, name)}, id: name)
  end

  # The coordinator treats the ingest value as opaque and keeps only the failed count.
  # A claim takes the caller's `now` as data; the coordinator stamps completions and
  # sweeps with the live monotonic clock, so tests pick claim times relative to it.
  defp run(server, key, ingest \\ fn -> {:ingested, 0} end, now \\ now()) do
    Idempotency.run("events", key, {[], nil}, now, ingest, server)
  end

  defp now do
    System.monotonic_time(:millisecond)
  end

  defp receipt(failed \\ 0) do
    {:duplicate, failed}
  end

  test "receipts retain failed outcomes but no event payloads", %{server: server} do
    payload = "private-event-payload"
    key = "private-retry-key"

    result = {:private, payload}

    assert run(server, key, fn -> {result, 3} end) == {:ran, result}
    assert run(server, key, fn -> flunk("duplicate ran ingestion") end) == receipt(3)
    assert :sys.get_state(server).monitors == %{}
    refute :erlang.term_to_binary(:sys.get_state(server)) =~ payload
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
            receive do: (:finish -> {:ingested, 0})
          end)

        send(test_pid, {:original, result})
      end)

    on_exit(fn -> Process.exit(owner, :kill) end)
    assert_receive :ingesting

    assert {:conflict, :changed} =
             Idempotency.run(
               "events",
               "same",
               {[1], nil},
               now(),
               fn -> flunk("changed request") end,
               server
             )

    for _ <- 1..12 do
      spawn(fn ->
        send(test_pid, {:duplicate, run(server, "same", fn -> flunk("duplicate") end)})
      end)
    end

    for _ <- 1..12 do
      assert_receive {:duplicate, {:conflict, :pending}}
    end

    assert run(server, "unrelated") == {:ran, :ingested}
    send(owner, :finish)
    assert_receive {:original, {:ran, :ingested}}
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}
    assert run(server, "same") == receipt()
  end

  test "retained identity strings do not pin a large request binary", %{server: server} do
    body = String.duplicate("x", 1_000_000)
    table = binary_part(body, 0, 64)
    key = binary_part(body, 100, 128)
    assert :binary.referenced_byte_size(key) > byte_size(key)

    assert {:ran, _} =
             Idempotency.run(table, key, {[], nil}, now(), fn -> {:ingested, 0} end, server)

    [{kept_table, kept_key}] = Map.keys(:sys.get_state(server).entries)
    assert :binary.referenced_byte_size(kept_table) == byte_size(kept_table)
    assert :binary.referenced_byte_size(kept_key) == byte_size(kept_key)
  end

  test "the full retention period starts at completion and repeats do not refresh it", %{
    server: server,
  } do
    test_pid = self()
    ingest = fn -> {:ingested, 0} end

    owner =
      spawn(fn ->
        # Claimed a minute ago: retention must not count from the claim.
        run(
          server,
          "slow",
          fn ->
            send(test_pid, :ingesting)
            receive do: (:finish -> {:ingested, 0})
          end,
          now() - 60_000
        )

        send(test_pid, :finished)
      end)

    on_exit(fn -> Process.exit(owner, :kill) end)
    assert_receive :ingesting
    assert run(server, "slow") == {:conflict, :pending}
    # The completion is stamped between these two reads.
    before_finish = now()
    send(owner, :finish)
    assert_receive :finished
    after_finish = now()
    assert run(server, "slow", ingest, before_finish + 9_999) == receipt()
    assert run(server, "slow", ingest, before_finish + 9_999) == receipt()
    assert run(server, "slow", ingest, after_finish + 10_000) == {:ran, :ingested}
  end

  test "periodic sweep drops expired entries even without another ingest" do
    server = start_server(retention_ms: 1)
    assert {:ran, _} = run(server, "expires")
    # The sweep reads the live clock; let the 1 ms retention pass.
    Process.sleep(2)
    send(server, :sweep)
    assert :sys.get_state(server).entries == %{}
    assert :gb_trees.is_empty(:sys.get_state(server).completed)
  end

  test "capacity evicts the oldest completed entry" do
    server = start_server(max_entries: 2)
    assert {:ran, _} = run(server, "oldest")
    # Completions in the same millisecond would tie on expiry; make "oldest" older.
    tick = now()
    Guardian.Test.Polling.eventually(fn -> now() > tick end)
    assert {:ran, _} = run(server, "newer")
    assert {:ran, _} = run(server, "newest")
    assert run(server, "newer") == receipt()
    assert run(server, "newest") == receipt()
    refute Map.has_key?(:sys.get_state(server).entries, {"events", "oldest"})
    assert {:ran, :ingested} = run(server, "oldest")
    assert map_size(:sys.get_state(server).entries) == 2
  end

  test "all-pending capacity fails open without evicting a live claim" do
    server = start_server(max_entries: 1)
    token = make_ref()
    digest = :crypto.hash(:sha256, :erlang.term_to_binary({[], nil}, [:deterministic]))

    assert GenServer.call(server, {:claim, {"events", "pending"}, digest, token, now()}) ==
             :claimed

    for _ <- 1..2 do
      assert run(server, "unprotected", fn -> {:unprotected, 2} end) == {:ran, :unprotected}
    end

    assert run(server, "pending") == {:conflict, :pending}
    assert map_size(:sys.get_state(server).entries) == 1
  end

  test "caller death retains uncertainty until expiry", %{server: server} do
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
    after_death = now()
    assert run(server, "killed") == {:conflict, :uncertain}
    ingest = fn -> {:ingested, 0} end
    assert {:ran, :ingested} = run(server, "killed", ingest, after_death + 10_000)
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

      assert run(server, key) == {:conflict, :uncertain}
    end

    assert Process.alive?(self())
    assert :sys.get_state(server).monitors == %{}
  end

  test "completion requires its token and owner and stale tokens cannot replace a new claim", %{
    server: server,
  } do
    identity = {"events", "token"}
    first = make_ref()
    assert GenServer.call(server, {:claim, identity, "digest", first, now()}) == :claimed
    test_pid = self()

    spawn(fn ->
      send(test_pid, {:forged, GenServer.call(server, {:finish, first, {:done, 99}})})
    end)

    assert_receive {:forged, :ok}
    assert :sys.get_state(server).entries[identity].status == :pending
    assert GenServer.call(server, {:finish, first, {:done, 0}}) == :ok
    later = now() + 10_000
    second = make_ref()
    assert GenServer.call(server, {:claim, identity, "digest", second, later}) == :claimed
    assert GenServer.call(server, {:finish, first, {:done, 99}}) == :ok
    assert :sys.get_state(server).entries[identity].token == second
  end

  test "unavailable coordinator fails open and a restart forgets keys" do
    name = :"idempotency_restart_#{System.unique_integer([:positive])}"
    pid = start_supervised!({Idempotency, name: name}, id: name)
    assert {:ran, :ingested} = run(name, "restart")
    assert run(name, "restart") == receipt()
    stop_supervised!(name)
    assert run(name, "restart") == {:ran, :ingested}
    refute Process.alive?(pid)
    start_supervised!({Idempotency, name: name}, id: name)
    assert {:ran, :ingested} = run(name, "restart")
  end

  test "a timed-out claim is cancelled after resume even when its caller lives", %{server: server} do
    :ok = :sys.suspend(server)

    try do
      assert run(server, "late") == {:ran, :ingested}
    after
      :ok = :sys.resume(server)
    end

    assert :sys.get_state(server).entries == %{}
    assert :sys.get_state(server).monitors == %{}
    assert {:ran, :ingested} = run(server, "late")
  end

  test "a timed-out completion still returns the original response", %{server: server} do
    try do
      assert run(server, "finish_late", fn ->
               :ok = :sys.suspend(server)
               {:ingested, 0}
             end) == {:ran, :ingested}
    after
      :ok = :sys.resume(server)
    end

    assert run(server, "finish_late") == receipt()
  end
end
