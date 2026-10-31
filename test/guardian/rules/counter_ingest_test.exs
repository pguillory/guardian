defmodule Guardian.Rules.CounterIngestTest do
  use ExUnit.Case, async: true
  import Guardian.Test.Rules
  alias Guardian.Counters.Store

  @api_key Application.compile_env!(:guardian, :admin_api_key)

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

  test "HTTP and MCP return LOOKUP=49/TRACK=50, SET decisions and historical stored fields" do
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

  test "invalid counter writes save nothing and valid counters execute through generated modules" do
    table = unique_table("counter_reject")
    remove_on_exit(table)

    for {word, source} <- [
          {:counter_window, "TRACK c = count() BY secret_group LAST '0s'"},
          {:counter_target, "LOOKUP x = c BY secret_group"},
        ] do
      assert {:error, {:rejected, [message]}} =
               Guardian.Rules.write_rule(table, "a", "\n" <> source)

      assert message =~ "#{table}/a.gsql line 2:"
      refute message =~ "secret_group"

      assert [%{kind: ^word}] =
               Guardian.Rules.RuleSet.validate(%{"#{table}/a.gsql" => source}).errors
    end

    assert Guardian.Rules.list_rules(table) == {:ok, []}
    assert Guardian.Rules.lookup(table) == nil

    assert {:ok, _} =
             Guardian.Rules.write_rule(
               table,
               "a",
               "TRACK c = count() LAST '1h'; LOOKUP prior = c"
             )

    module = Guardian.Rules.lookup(table)
    assert module.apply(%{}) == %{"c" => 1, "prior" => 0}
    assert [{:ok, %{"c" => 2, "prior" => 1}}] = Guardian.Engine.ingest_events(table, [%{}])
  end

  # Store operations take the current local monotonic milliseconds as data.
  defp now do
    System.monotonic_time(:millisecond)
  end
end
