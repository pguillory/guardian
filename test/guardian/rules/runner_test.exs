defmodule Guardian.Rules.RunnerTest do
  use ExUnit.Case, async: true
  import Guardian.Test.Rules

  test "outcomes stay in order, a non-object fails alone, and rows get no metadata fields" do
    table = unique_table("rules_runner")
    with_rules(%{"#{table}/r.gsql" => "SET ran = true"})

    spoofed = %{
      "arrival" => 1,
      "unix_ms" => 1,
      "arrival_ms" => 1,
      "monotonic_ms" => 1,
      "timestamp" => "old",
      "counters" => 99,
    }

    ran = Map.put(spoofed, "ran", true)

    assert [{:ok, ^ran}, {:error, "event is not a JSON object"}, {:ok, %{"ran" => true}}] =
             Guardian.Engine.ingest_events(table, [spoofed, false, %{}])

    assert MapSet.new(Guardian.Storage.dump_table(table)) ==
             MapSet.new([ran, %{"ran" => true}])

    # The convenience entry captures its own private arrival.
    assert Guardian.Rules.run(table, [%{"n" => 1}]) == [{:ok, %{"n" => 1, "ran" => true}}]
  end
end
