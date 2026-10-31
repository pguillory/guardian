defmodule Guardian.Rules.RunnerTest do
  # Not async: publish_module replaces the published map, which Rules.Server also writes.
  use ExUnit.Case, async: false
  import Guardian.Test.Rules
  alias Guardian.Counters.Arrival
  alias Guardian.Test.Counters.Budget, as: CounterBudgetHelper

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

      # Past the worker's heap limit: Runner fails this row and starts a new worker.
      if row["over_heap_limit"] do
        CounterBudgetHelper.charge_us(event.counters.batch, 50_000)
        Map.put(row, "list", Enum.to_list(1..10_000_000))
      else
        row
      end
    end
  end

  test "Runner preserves batch reservations and arrival coordinates through worker replacement" do
    table = unique_table("counter_worker_metadata")
    publish_module(table, MetadataRules)
    Guardian.Test.Env.put(counter_metadata_observer: self())
    first = Arrival.now()
    second = %{first | unix_ms: first.unix_ms + 1}

    assert [{:error, _}, {:ok, %{"ok" => true}}] =
             Guardian.Rules.run_with_metadata(table, [
               {%{"over_heap_limit" => true}, first},
               {%{"ok" => true}, second},
             ])

    assert_receive {:metadata, first_worker, _, one}
    assert_receive {:metadata, second_worker, _, two}
    assert %Guardian.Counters.Context{} = one.counters
    assert %Guardian.Counters.Context{} = two.counters
    refute first_worker == second_worker
    assert one.arrival == first
    assert two.arrival == second
    assert one.arrival.monotonic_ms == two.arrival.monotonic_ms
    assert one.counters.batch == two.counters.batch
    assert CounterBudgetHelper.remaining_us(two.counters.batch) == 200_000
    assert two.counters.members == [node() | Node.list()]
    assert two.counters.deadline > one.counters.deadline
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
    assert is_reference(private.counters.batch)
    assert_receive {:metadata, _, %{}, second}
    assert second.counters.batch == private.counters.batch
    assert MapSet.new(Guardian.Storage.dump_table(table)) == MapSet.new([spoofed, %{}])
    # The convenience entry captures its own private arrival and batch context.
    assert [{:ok, %{}}] = Guardian.Rules.run(table, [%{}])
    assert_receive {:metadata, _, %{}, direct}
    refute direct.counters.batch == private.counters.batch
  end
end
