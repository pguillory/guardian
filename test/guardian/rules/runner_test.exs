defmodule Guardian.Rules.RunnerTest do
  # Not async: publish_module replaces the published map, which Rules.Server also writes.
  use ExUnit.Case, async: false
  import Guardian.Test.Rules

  defp ingest(table, events) do
    Guardian.Engine.ingest_events(table, events)
  end

  defmodule LimitRules do
    def apply(%{"big" => n} = row, _event) do
      Map.put(row, "list", Enum.to_list(1..n))
    end

    def apply(row, _event) do
      Map.put(row, "ran", true)
    end
  end

  test "an event over its heap limit fails alone; outcomes stay in order" do
    table = unique_table("rules_limits")
    publish_module(table, LimitRules)
    Guardian.Test.Env.put(query_max_heap_mb: 4)

    assert [ok1, big, ok2] =
             ingest(table, [%{"n" => 1}, %{"big" => 10_000_000}, %{"n" => 2}])

    assert {:ok, %{"n" => 1, "ran" => true}} = ok1

    assert {:error,
            "rules for #{table} exceeded their time or memory limit; the event was not stored"} ==
             big

    assert {:ok, %{"n" => 2, "ran" => true}} = ok2

    assert table |> Guardian.Storage.dump_table() |> Enum.map(& &1["n"]) |> Enum.sort() == [1, 2]
  end

  test "a table whose stored rules are invalid fails its events; other tables are unaffected" do
    table = unique_table("rules_invalid_table")
    publish_module(table, {:invalid, "#{table}/r.gsql line 1: Expected field name"})

    assert [{:error, message}] = ingest(table, [%{"x" => 1}])

    assert message ==
             "rules for #{table} are invalid (#{table}/r.gsql line 1: Expected field name); the event was not stored"

    assert Guardian.Storage.dump_table(table) == []

    other = unique_table("rules_other")
    assert [{:ok, %{"x" => 1}}] = ingest(other, [%{"x" => 1}])
  end

  defmodule MetadataRules do
    def apply(row, event) do
      send(
        Application.fetch_env!(:guardian, :counter_metadata_observer),
        {:metadata, self(), row, event}
      )

      row
    end
  end

  test "Engine arrival metadata stays outside caller rows and is never stored" do
    table = unique_table("counter_engine_metadata")
    publish_module(table, MetadataRules)
    Guardian.Test.Env.put(counter_metadata_observer: self())

    spoofed = %{
      "arrival" => 1,
      "unix_ms" => 1,
      "arrival_ms" => 1,
      "monotonic_ms" => 1,
      "timestamp" => "old",
      "counters" => 99,
    }

    before = System.system_time(:millisecond)

    assert [{:ok, ^spoofed}, {:error, "event is not a JSON object"}, {:ok, %{}}] =
             ingest(table, [spoofed, false, %{}])

    assert_receive {:metadata, _, ^spoofed, private}
    assert private.arrival.unix_ms >= before
    assert private.arrival.unix_ms <= System.system_time(:millisecond)
    assert_receive {:metadata, _, %{}, _second}
    assert MapSet.new(Guardian.Storage.dump_table(table)) == MapSet.new([spoofed, %{}])
    # The convenience entry captures its own private arrival.
    assert [{:ok, %{}}] = Guardian.Rules.run(table, [%{}])
    assert_receive {:metadata, _, %{}, _direct}
  end
end
