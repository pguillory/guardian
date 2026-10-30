defmodule Guardian.Rules.CounterIngestTest do
  # Not async: with_rules writes the shared rule store; relaxes the node-wide counter
  # budgets and pauses the node's counter store.
  use ExUnit.Case, async: false
  import Guardian.Test.Rules
  alias Guardian.Counters.Store

  @api_key Application.compile_env!(:guardian, :admin_api_key)

  setup do
    # Named counter processes and cooldowns are shared; these tests are serial.
    assert Guardian.Counters.Supervisor.available?()
    :ets.delete_all_objects(Guardian.Counters.Budget)

    on_exit(fn ->
      assert Guardian.Counters.Supervisor.available?()
      :ets.delete_all_objects(Guardian.Counters.Budget)
    end)

    :ok
  end

  defp http(arguments) do
    conn =
      Plug.Test.conn(:post, "/api/json/send_events", arguments)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("x-api-key", @api_key)
      |> Guardian.Web.MainRouter.call(nil)

    assert conn.status == 200
    Jason.decode!(conn.resp_body)
  end

  defp mcp(tool, arguments) do
    assert {:ok, response} = Guardian.Test.MCPClient.call_tool(tool, arguments)
    refute response.result["isError"] == true
    [%{"type" => "text", "text" => text}] = response.result["content"]
    Jason.decode!(text)
  end

  defp ingest(table, events) do
    Guardian.Engine.ingest_events(table, events)
  end

  # The table's stored TRACK, as whole-set preparation builds it.
  defp track(table) do
    {:ok, files} = Guardian.Rules.list_rules(table)

    sources =
      Map.new(files, fn %{name: name} ->
        {:ok, source} = Guardian.Rules.read_rule(table, name)
        {Guardian.Rules.RuleSet.key(table, name), source}
      end)

    {:ok, plan} = Guardian.Rules.RuleSet.prepare(sources).candidates[table]
    Enum.find(plan.steps, &(&1.kind == :track))
  end

  defp await_cooldown(owner) do
    Guardian.Test.Polling.eventually(fn ->
      case :ets.lookup(Guardian.Counters.Budget, owner) do
        [] -> true
        [{_, until}] -> until <= System.monotonic_time(:microsecond)
      end
    end)
  end

  test "HTTP and MCP return LOOKUP=49/TRACK=50, SET decisions and historical stored fields" do
    Guardian.Test.Counters.Budget.relax()
    Guardian.Test.MCPClient.start()

    for interface <- [:http, :mcp] do
      table = unique_table("counter_#{interface}")

      source = """
      TRACK hits = count() BY group_key LAST '1h';
      SET blocked = hits >= 50;
      UNSET secret;
      LOOKUP prior = hits BY group_key;
      SET group_key = lower(ip)
      """

      assert mcp("write_rule", %{"table" => table, "name" => "r", "source" => source})["saved"]
      on_exit(fn -> Guardian.Rules.delete_rule(table, "r") end)
      # Identical TRACK copies execute just once even through public compilation.
      with_rules(%{"#{table}/copy.gsql" => "TRACK hits = count() BY group_key LAST '1h'"})
      send_events = if interface == :http, do: &http/1, else: &mcp("send_events", &1)

      events =
        for n <- 1..50,
            do: %{
              "n" => n,
              "ip" => "A",
              "secret" => "private",
              "timestamp" => "1900-01-01 00:00:00",
              "arrival_ms" => 0,
              "monotonic_ms" => 0,
            }

      args = %{
        "table" => table,
        "events" => events,
        "return_keys" => ~w(hits prior blocked secret absent),
      }

      assert %{"results" => results} = send_events.(args)

      for {result, n} <- Enum.with_index(results, 1) do
        assert result == %{
                 "success" => true,
                 "event" => %{
                   "hits" => n,
                   "prior" => n - 1,
                   "blocked" => n >= 50,
                   "secret" => nil,
                   "absent" => nil,
                 },
               }
      end

      assert %{"results" => [%{"event" => all}]} =
               send_events.(%{"table" => table, "events" => [%{"ip" => "A"}]})

      assert all == %{
               "ip" => "A",
               "group_key" => "a",
               "hits" => 51,
               "prior" => 50,
               "blocked" => true,
             }

      assert %{"results" => [%{"event" => null_keys}]} =
               send_events.(%{
                 "table" => table,
                 "events" => [%{"ip" => "A"}],
                 "return_keys" => nil,
               })

      assert null_keys["hits"] == 52

      assert send_events.(%{
               "table" => table,
               "events" => [%{"ip" => "A"}],
               "return_keys" => [],
             })["results"] == [%{"success" => true, "event" => %{}}]

      # The forged timestamps are ordinary fields; no private coordinate was added.
      first = Enum.find(Guardian.Storage.dump_table(table), &(&1["n"] == 1))
      assert first["timestamp"] == "1900-01-01 00:00:00"
      assert first["arrival_ms"] == 0
      refute Map.has_key?(first, "secret")

      assert {:ok, _, [[49, 50, true]]} =
               Guardian.Query.execute("SELECT prior, hits, blocked FROM #{table} WHERE n = 50")

      assert {:ok, _} = Guardian.Rules.delete_rule(table, "copy")

      assert {:ok, _} =
               Guardian.Rules.write_rule(table, "r", String.replace(source, "'1h'", "'2h'"))

      assert [{:ok, %{"hits" => 1}}] = ingest(table, [%{"ip" => "A"}])

      assert {:ok, _, [[49, 50, true]]} =
               Guardian.Query.execute("SELECT prior, hits, blocked FROM #{table} WHERE n = 50")
    end
  end

  test "cross-table lookups preserve typed/null groups and all enabled aggregate operators" do
    Guardian.Test.Counters.Budget.relax()
    table = unique_table("live_aggregates")
    reader = unique_table("live_aggregate_reader")

    source = """
    TRACK hits = count() BY g LAST '1h'; TRACK present = count(v) BY g LAST '1h';
    TRACK distinct_n = count_distinct(v) BY g LAST '1h'; TRACK total = sum(v) BY g LAST '1h';
    TRACK smallest = min(v) BY g LAST '1h'; TRACK largest = max(v) BY g LAST '1h';
    TRACK mean = avg(v) BY g LAST '1h'
    """

    with_rules(%{"#{table}/r.gsql" => source})

    assert {:ok, _} =
             Guardian.Rules.write_rule(reader, "r", "LOOKUP prior = hits FROM #{table} BY g")

    on_exit(fn -> Guardian.Rules.delete_rule(reader, "r") end)

    for group <- [1, 1.0, "1", nil] do
      assert [_, _, {:ok, row}] =
               ingest(table, for(value <- [nil, 2, 4], do: %{"g" => group, "v" => value}))

      assert Map.take(row, ~w(hits present distinct_n total smallest largest mean)) ==
               %{
                 "hits" => 3,
                 "present" => 2,
                 "distinct_n" => 2,
                 "total" => 6,
                 "smallest" => 2,
                 "largest" => 4,
                 "mean" => 3.0,
               }

      assert [{:ok, read}] = ingest(reader, [%{"g" => group}])
      assert read["prior"] == 3
    end

    assert [{:ok, %{"g" => "missing", "prior" => 0}}] = ingest(reader, [%{"g" => "missing"}])
  end

  test "a count outside int64 is refused where the event is stored, keeping the rest" do
    Guardian.Test.Counters.Budget.relax()
    table = unique_table("live_counter_int64")
    with_rules(%{"#{table}/r.gsql" => "TRACK hits = count() LAST '1h'; SET seen = true"})
    definition = track(table).definition
    bucket = Integer.floor_div(System.os_time(:millisecond), definition.bucket_ms)
    max = Guardian.Query.Numeric.max_int()
    assert {:ok, ^max} = Store.incr({definition.identity, {}, bucket}, max, 60_000, now(), [])

    assert [{:ok, row}] = ingest(table, [%{"v" => 1}])
    refute Map.has_key?(row, "hits")
    assert Guardian.Storage.dump_table(table) == [%{"v" => 1, "seen" => true}]
  end

  test "unkeyed resubmissions count twice; completed HTTP/MCP keyed retries return only a receipt" do
    Guardian.Test.Counters.Budget.relax()
    Guardian.Test.MCPClient.start()
    table = unique_table("live_counter_retry")
    with_rules(%{"#{table}/r.gsql" => "TRACK hits = count() LAST '1h'"})
    args = %{"table" => table, "events" => [%{}], "return_keys" => ["hits"]}
    assert http(args)["results"] == [%{"success" => true, "event" => %{"hits" => 1}}]

    assert mcp("send_events", args)["results"] == [
             %{"success" => true, "event" => %{"hits" => 2}},
           ]

    keyed = Map.put(args, "idempotency_key", "same-node")
    assert http(keyed)["results"] == [%{"success" => true, "event" => %{"hits" => 3}}]

    assert mcp("send_events", keyed) == %{
             "status" => 200,
             "duplicate" => true,
             "failed_events" => 0,
           }

    assert [{:ok, %{"hits" => 4}}] = ingest(table, [%{}])
    assert length(Guardian.Storage.dump_table(table)) == 4
  end

  test "a later rule or storage failure leaves earlier counter side effects without replay" do
    Guardian.Test.Counters.Budget.relax()
    table = unique_table("live_counter_partial")

    with_rules(%{
      "#{table}/r.gsql" =>
        "TRACK hits = count() LAST '1h'; SET result = test_raise(bad) + hits; UNSET secret",
    })

    ExUnit.CaptureLog.capture_log(fn ->
      assert {_reason, _stack} = catch_exit(ingest(table, [%{"bad" => 1}]))
    end)

    assert Guardian.Storage.dump_table(table) == []

    # A fresh table guarantees the one-call fake is its only mutable segment.
    storage_table = unique_table("live_counter_storage_partial")
    with_rules(%{"#{storage_table}/r.gsql" => "TRACK hits = count() LAST '1h'"})

    Guardian.Test.Segments.intercept_append(storage_table, fn from, _row ->
      GenServer.reply(from, {:error, :invalid_value})
    end)

    assert [{:error, "value cannot be stored; the event was not stored"}] =
             ingest(storage_table, [%{}])

    assert [{:ok, %{"hits" => 2}}] = ingest(storage_table, [%{}])
    assert Guardian.Storage.dump_table(storage_table) == [%{"hits" => 2}]
  end

  test "a slow local Store bounds a long many-rule batch, cools down and recovers without queued writes" do
    table = unique_table("live_counter_slow")
    source = Enum.map_join(1..16, ";", &"TRACK c#{&1} = count() LAST '1h'") <> "; UNSET secret"
    with_rules(%{"#{table}/r.gsql" => source})
    store = Process.whereis(Store)
    pause = Guardian.Test.Counters.StorePause.pause(store)

    on_exit(fn ->
      if Process.alive?(elem(pause, 0)), do: Guardian.Test.Counters.StorePause.resume(pause)
    end)

    started = System.monotonic_time(:millisecond)

    try do
      results = ingest(table, List.duplicate(%{"secret" => "private", "c1" => 99}, 100))
      assert Enum.all?(results, fn {:ok, row} -> row == Map.new(1..16, &{"c#{&1}", 0}) end)
      assert System.monotonic_time(:millisecond) - started < 1_500
      assert [{_, _}] = :ets.lookup(Guardian.Counters.Budget, node())
    after
      :ok = Guardian.Test.Counters.StorePause.resume(pause)
    end

    await_cooldown(node())
    assert [{:ok, row}] = ingest(table, [%{}])
    assert row == Map.new(1..16, &{"c#{&1}", 1})
  end

  test "HTTP and MCP counter failure stays fail-open" do
    Guardian.Test.MCPClient.start()
    table = unique_table("live_counter_redaction")
    marker = "PRIVATE-#{System.unique_integer([:positive])}"

    with_rules(%{
      "#{table}/r.gsql" =>
        "TRACK hits = count() BY concat(secret, '#{marker}') LAST '1h'; UNSET secret",
    })

    args = %{
      "table" => table,
      "events" => [%{"secret" => marker, "hits" => 99}],
      "return_keys" => ["hits", "secret"],
    }

    store = Process.whereis(Store)
    pause = Guardian.Test.Counters.StorePause.pause(store)

    on_exit(fn ->
      if Process.alive?(elem(pause, 0)), do: Guardian.Test.Counters.StorePause.resume(pause)
    end)

    ExUnit.CaptureLog.capture_log(fn ->
      for send_events <- [&http/1, &mcp("send_events", &1)] do
        # Exercise a real timeout for each interface, not the other's cooldown.
        :ets.delete(Guardian.Counters.Budget, node())

        assert send_events.(args)["results"] == [
                 %{"success" => true, "event" => %{"hits" => 0, "secret" => nil}},
               ]
      end
    end)

    :ok = Guardian.Test.Counters.StorePause.resume(pause)
  end

  @tag :cluster
  test "real peer owner handles healthy concurrent events, failure cooldown and recovery" do
    table = unique_table("live_counter_peer")

    with_rules(%{
      "#{table}/r.gsql" =>
        "TRACK hits = count() BY g LAST '1h'; LOOKUP prior = hits BY g; UNSET secret",
    })

    distributed = Guardian.Test.Cluster.ensure_distributed()
    {peer, peer_node} = Guardian.Test.Cluster.start_peer(nil)

    on_exit(fn ->
      if Process.alive?(peer), do: :peer.stop(peer)
      if distributed, do: Node.stop()
    end)

    assert {:ok, _} = :erpc.call(peer_node, Guardian.Test.Counters.Client, :start_store, [])
    Guardian.Test.Counters.Client.await_ready(peer_node)
    # One slow call under host load would cool the peer down and zero the burst.
    production_budgets = Guardian.Test.Counters.Budget.relax([peer_node])
    identity = track(table).definition.identity

    group =
      Enum.find(
        1..1_000,
        &(Guardian.Counters.Transport.owner({identity, {&1}}, [node(), peer_node]) == peer_node)
      )

    assert group

    results =
      1..60
      |> Task.async_stream(fn _ -> ingest(table, [%{"g" => group}]) end, max_concurrency: 4)
      |> Enum.map(fn {:ok, [{:ok, row}]} -> row["hits"] end)

    # Concurrent arrivals can straddle buckets: individual reads are not a snapshot.
    # The following sequential event proves every update was counted.
    assert Enum.all?(results, &(is_integer(&1) and &1 in 1..60))
    assert [{:ok, %{"hits" => 61, "prior" => 60}}] = ingest(table, [%{"g" => group}])
    # Failure, cooldown and recovery run on production budgets.
    production_budgets.()

    pause = :erpc.call(peer_node, Guardian.Test.Counters.StorePause, :pause, [Store])

    on_exit(fn ->
      if Process.alive?(peer) and :erpc.call(peer_node, Process, :alive?, [elem(pause, 0)]),
        do: :erpc.call(peer_node, Guardian.Test.Counters.StorePause, :resume, [pause])
    end)

    started = System.monotonic_time(:millisecond)

    try do
      results =
        ingest(table, List.duplicate(%{"g" => group, "secret" => "private", "hits" => 99}, 60))

      assert Enum.all?(results, &match?({:ok, %{"hits" => 0, "prior" => 0}}, &1))
      assert Enum.all?(results, fn {:ok, row} -> not Map.has_key?(row, "secret") end)
      assert System.monotonic_time(:millisecond) - started < 1_500
      assert [{_, _}] = :ets.lookup(Guardian.Counters.Budget, peer_node)
    after
      :ok = :erpc.call(peer_node, Guardian.Test.Counters.StorePause, :resume, [pause])
    end

    await_cooldown(peer_node)
    assert [{:ok, %{"hits" => 62, "prior" => 61}}] = ingest(table, [%{"g" => group}])
    assert :ok = :erpc.call(peer_node, GenServer, :stop, [Store])
    assert [{:ok, %{"hits" => 0}}] = ingest(table, [%{"g" => group}])
    assert {:ok, _} = :erpc.call(peer_node, Guardian.Test.Counters.Client, :start_store, [])
    Guardian.Test.Counters.Client.await_ready(peer_node)
    await_cooldown(peer_node)
    assert [{:ok, %{"hits" => 1, "prior" => 0}}] = ingest(table, [%{"g" => group}])
  end

  # Store operations take the current local monotonic milliseconds as data.
  defp now do
    System.monotonic_time(:millisecond)
  end
end
