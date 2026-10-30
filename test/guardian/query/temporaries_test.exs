defmodule Guardian.Query.TemporariesTest do
  # Query temporaries: SELECT without FROM, the schema table, reassembled GROUP BY
  # output.
  use ExUnit.Case, async: true
  import Guardian.Test.Query, only: [run_sql: 1]

  alias Guardian.Query.Constant
  alias Guardian.Query.Evaluation
  alias Guardian.Query.Evaluation.SegmentSnapshot
  alias Guardian.Storage.Column

  defp table do
    "temporaries_#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
  end

  # Appends row v, then the next, until it gets :stop, then tells the parent how many
  # rows it wrote.
  defp append_until_stopped(table, progress, parent, v) do
    :counters.add(progress, 1, 1)
    :ok = Guardian.Storage.append(table, k: rem(v, 7), v: 1)
    :counters.add(progress, 2, 1)

    receive do
      :stop -> send(parent, {:written, v})
    after
      0 -> append_until_stopped(table, progress, parent, v + 1)
    end
  end

  describe "results" do
    test "SELECT without FROM" do
      assert run_sql("select 1, 'a'") == [[1, "a"]]
      assert run_sql("select nosuchcolumn") == [[nil]]
    end

    test "the schema table" do
      table = table()
      :ok = Guardian.Storage.append(table, a: 1, b: "x")
      :ok = Guardian.Storage.append(table, a: 2)

      assert run_sql(
               "select key, count, int_count, string_count from schema where table = '#{table}' order by key"
             ) ==
               [["a", 2, 2, 0], ["b", 1, 0, 1]]

      assert [table] in run_sql("show tables")
      assert run_sql("desc #{table}") == [["a"], ["b"]]
    end

    test "reassembled GROUP BY output" do
      table = table()
      for v <- 1..10, do: :ok = Guardian.Storage.append(table, k: rem(v, 3), v: v)

      assert run_sql("select k, count(*) from #{table} group by k having count(*) > 3") ==
               [[1, 4]]

      assert run_sql("select k, sum(v) * 10 from #{table} group by k order by k") ==
               [[0, 180], [1, 220], [2, 150]]

      assert run_sql("select k, sum(v) * 10 from #{table} group by k order by k desc limit 1") ==
               [[2, 150]]
    end

    # Reassembly packs 16,384 rows per temporary, per partition, and GROUP BY has two
    # partitions, so more than 32,768 groups crosses the boundary in both.
    test "reassembly across temporaries loses and duplicates no rows" do
      table = table()
      n = 40_000
      for k <- 1..n, do: :ok = Guardian.Storage.append(table, k: k)

      rows = run_sql("select k, count(*) from #{table} group by k having count(*) = 1")
      assert length(rows) == n
      assert rows |> Enum.map(&hd/1) |> Enum.sort() == Enum.to_list(1..n)
    end
  end

  test "reassembling queries during ingest see consistent results" do
    table = table()
    # Index 1 counts appends started, index 2 appends acknowledged. A query sees every
    # acknowledged row and none that was not started.
    progress = :counters.new(2, [])
    parent = self()

    # The writer keeps appending until a check has seen 20,000 rows, so the checks run
    # during ingest, across a segment rollover, however fast the writer is.
    writer = spawn_link(fn -> append_until_stopped(table, progress, parent, 1) end)

    query = "select k, sum(v) from #{table} group by k having count(*) > 0"

    check = fn ->
      low = :counters.get(progress, 2)
      rows = run_sql(query)
      high = :counters.get(progress, 1)
      keys = Enum.map(rows, &hd/1)
      assert keys == Enum.uniq(keys)
      total = rows |> Enum.map(&List.last/1) |> Enum.sum()
      assert total >= low and total <= high, inspect({low, total, high})
      total
    end

    totals = Stream.repeatedly(check) |> Enum.take_while(&(&1 < 20_000))
    send(writer, :stop)
    assert_receive {:written, written}, 60_000
    assert totals == Enum.sort(totals)
    assert check.() == written
    expected = 1..written |> Enum.frequencies_by(&rem(&1, 7)) |> Enum.map(fn {k, n} -> [k, n] end)
    assert Enum.sort(run_sql(query)) == Enum.sort(expected)
  end

  describe "column snapshots" do
    test "evaluate a column, a missing key, and an empty snapshot" do
      values = [1, nil, true, "s", [1, 2], 1.5]

      snapshot = %SegmentSnapshot{
        columns: %{"a" => Column.from_list(values)},
        count: length(values),
      }

      assert snapshot |> Evaluation.eval("a") |> Column.to_list() == values
      assert snapshot |> Evaluation.eval("b") |> Column.to_list() == List.duplicate(nil, 6)

      empty = %SegmentSnapshot{columns: %{"a" => Column.from_list([])}, count: 0}
      assert empty |> Evaluation.eval("a") |> Column.to_list() == []
      assert empty |> Evaluation.eval("b") |> Column.to_list() == []
    end

    test "read a column cut to the snapshot's row count" do
      columns = %{"a" => Column.from_list([1, 2, 3])}
      snapshot = %SegmentSnapshot{columns: columns, count: 2}

      assert snapshot |> Evaluation.eval("a") |> Column.to_list() == [1, 2]
      assert %Constant{value: nil, count: 2} = Evaluation.read_column(snapshot, "b")
    end
  end

  describe "stored segment snapshots" do
    test "read a stored column, and a missing one as nulls" do
      table = "snapshot_read_#{System.unique_integer([:positive])}"
      on_exit(fn -> :ok = Guardian.Storage.delete_table(table) end)
      for v <- 1..3, do: :ok = Guardian.Storage.append(table, v: v)
      [id] = table |> Guardian.Storage.segment_ids() |> Enum.to_list()
      snapshot = Evaluation.snapshot!(id)

      assert snapshot |> Evaluation.eval("v") |> Column.to_list() == [1, 2, 3]
      assert %Constant{value: nil, count: 3} = Evaluation.read_column(snapshot, "w")
      assert %Constant{value: nil, count: 2} = Evaluation.read_column(%{snapshot | count: 2}, "w")

      assert %{snapshot | count: 2} |> Evaluation.eval("v") |> Column.to_list() == [1, 2]
    end

    test "a snapshot naming neither a segment ID nor columns raises" do
      snapshot = %SegmentSnapshot{segment: self(), count: 1}

      assert_raise ArgumentError, ~r/not a segment ID or column snapshot/, fn ->
        Evaluation.read_column(snapshot, "v")
      end
    end
  end
end
