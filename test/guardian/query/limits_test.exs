defmodule Guardian.Query.LimitsTest do
  use ExUnit.Case, async: true
  import Guardian.Test.Query, only: [run_sql: 1]

  setup do
    table = "limits_#{System.unique_integer([:positive])}"

    Guardian.Engine.ingest_events(
      table,
      Enum.map(1..30, &%{"v" => &1, "k" => rem(&1, 3), "s" => "row #{&1}"})
    )

    %{table: table}
  end

  test "a query without LIMIT returns at most 10,000 rows; aggregates read them all" do
    table = "limits_big_#{System.unique_integer([:positive])}"

    1..10_001
    |> Enum.map(&%{"v" => &1})
    |> Enum.chunk_every(10_000)
    |> Enum.each(&Guardian.Engine.ingest_events(table, &1))

    assert length(run_sql("SELECT v FROM #{table}")) == 10_000
    assert run_sql("SELECT count(), max(v) FROM #{table}") == [[10_001, 10_001]]
    assert length(run_sql("SELECT v, count() FROM #{table} GROUP BY v")) == 10_000

    sorted = run_sql("SELECT v FROM #{table} ORDER BY v DESC")
    assert length(sorted) == 10_000
    assert hd(sorted) == [10_001]
    assert List.last(sorted) == [2]
  end

  describe "string functions" do
    # Strings that functions build are cut to the cap (Guardian.Query.Text), never refused.
    @max Guardian.Query.Text.max_bytes()

    test "lpad and rpad of a huge size give a string at the cap" do
      assert [[left, right]] = run_sql("SELECT lpad('x', 2000000000), rpad('x', 2000000000)")
      assert left == String.duplicate(" ", @max)
      assert right == "x" <> String.duplicate(" ", @max - 1)
      assert run_sql("SELECT lpad('x', 3), rpad('x', 3)") == [["  x", "x  "]]
    end

    test "concat, ||, and replace cut results at the cap", %{table: table} do
      half = String.duplicate("a", div(@max, 2))
      assert [[result]] = run_sql("SELECT concat('#{half}', '#{half}', 'b')")
      assert result == half <> half
      assert [[^result]] = run_sql("SELECT '#{half}' || '#{half}b'")

      assert [[replaced]] = run_sql("SELECT replace(s, '[a-z]', '#{half}') FROM #{table} LIMIT 1")
      assert byte_size(replaced) == @max
    end
  end

  test "replace and RLIKE run over a stored table", %{table: table} do
    assert run_sql("SELECT replace(s, '[0-9]+', ':n') FROM #{table} WHERE v <= 2") ==
             [["row :n"], ["row :n"]]

    assert run_sql("SELECT count() FROM #{table} WHERE s RLIKE '^row [0-9]{2}$'") == [[21]]
  end

  test "factorial is null where the result doesn't fit in 64 bits" do
    assert run_sql("SELECT factorial(100000000), factorial(21)") == [[nil, nil]]

    assert run_sql("SELECT factorial(0), factorial(5), factorial(20)") == [
             [1, 120, 2_432_902_008_176_640_000],
           ]
  end
end
