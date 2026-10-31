defmodule Guardian.Rules.CounterIngestClusterTest do
  # Not async: starts connected peers, which every query in this VM then fans out to, and
  # which own some of every async test's counters.
  use ExUnit.Case, async: false
  @moduletag :cluster
  import Guardian.Test.Rules

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

  test "a peer owner counts concurrent events, and a peer with no store gives the missing result" do
    table = unique_table("live_counter_peer")

    with_rules(%{
      "#{table}/r.gsql" =>
        "TRACK hits = count() BY g LAST '1h'; LOOKUP prior = hits BY g; UNSET secret",
    })

    {_peer, peer_node} = Guardian.Test.Cluster.bare_peer()
    assert {:ok, _} = :erpc.call(peer_node, Guardian.Test.Counters.Client, :start_store, [])
    Guardian.Test.Counters.Client.await_ready(peer_node)
    # Connected, with the code loaded, as a peer still booting: no store is running.
    {_booting, booting_node} = Guardian.Test.Cluster.bare_peer()
    :ok = :erpc.call(booting_node, Guardian.Test.Counters.Client, :preload, [])
    identity = track(table).definition.identity
    members = [node(), peer_node, booting_node]

    group_owned_by = fn owner ->
      Enum.find(
        1..1_000,
        &(Guardian.Counters.Transport.owner({identity, {&1}}, members) == owner)
      )
    end

    group = group_owned_by.(peer_node)

    results =
      1..60
      |> Task.async_stream(fn _ -> ingest(table, [%{"g" => group}]) end, max_concurrency: 4)
      |> Enum.map(fn {:ok, [{:ok, row}]} -> row["hits"] end)

    # Concurrent arrivals can straddle buckets: individual reads are not a snapshot.
    # The following sequential event proves every update was counted.
    assert Enum.all?(results, &(is_integer(&1) and &1 in 1..60))
    assert [{:ok, %{"hits" => 61, "prior" => 60}}] = ingest(table, [%{"g" => group}])

    assert [{:ok, row}] =
             ingest(table, [%{"g" => group_owned_by.(booting_node), "secret" => "private"}])

    assert %{"hits" => 0, "prior" => 0} = row
    refute Map.has_key?(row, "secret")
  end
end
