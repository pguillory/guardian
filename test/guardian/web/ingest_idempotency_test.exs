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

  test "receipts retain failed outcomes", %{server: server} do
    key = "retry-key"
    result = {:result, "value"}

    assert run(server, key, fn -> {result, 3} end) == {:ran, result}
    assert run(server, key, fn -> flunk("duplicate ran ingestion") end) == receipt(3)
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
    assert {:ran, :ingested} = run(server, "oldest")
  end

  test "all-pending capacity fails open without evicting a live claim" do
    server = start_server(max_entries: 1)
    test_pid = self()

    owner =
      spawn(fn ->
        run(server, "pending", fn ->
          send(test_pid, :ingesting)
          receive do: (:finish -> {:ingested, 0})
        end)
      end)

    on_exit(fn -> Process.exit(owner, :kill) end)
    assert_receive :ingesting

    for _ <- 1..2 do
      assert run(server, "unprotected", fn -> {:unprotected, 2} end) == {:ran, :unprotected}
    end

    assert run(server, "pending") == {:conflict, :pending}
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
    Guardian.Test.Polling.eventually(fn -> run(server, "killed") == {:conflict, :uncertain} end)
    after_death = now()
    ingest = fn -> {:ingested, 0} end
    assert {:ran, :ingested} = run(server, "killed", ingest, after_death + 10_000)
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
  end

  test "unavailable coordinator fails open and a restart forgets keys" do
    name = :"idempotency_restart_#{System.unique_integer([:positive])}"
    start_supervised!({Idempotency, name: name}, id: name)
    assert {:ran, :ingested} = run(name, "restart")
    assert run(name, "restart") == receipt()
    stop_supervised!(name)
    assert run(name, "restart") == {:ran, :ingested}
    start_supervised!({Idempotency, name: name}, id: name)
    assert {:ran, :ingested} = run(name, "restart")
  end
end
