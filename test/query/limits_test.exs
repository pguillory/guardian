defmodule Query.LimitsTest do
  # Changes limits in the application environment, so not async.
  use ExUnit.Case, async: false
  import TestHelpers, only: [run_sql: 1]

  @keys [:query_max_result_rows, :query_max_result_bytes]

  setup do
    saved = Application.get_all_env(:guardian) |> Keyword.take(@keys)

    on_exit(fn ->
      Enum.each(@keys, fn key ->
        case Keyword.fetch(saved, key) do
          {:ok, value} -> Application.put_env(:guardian, key, value)
          :error -> Application.delete_env(:guardian, key)
        end
      end)
    end)

    table = "limits_#{System.unique_integer([:positive])}"

    Engine.ingest_events(
      table,
      Enum.map(1..30, &%{"v" => &1, "k" => rem(&1, 3), "s" => "row #{&1}"})
    )

    %{table: table}
  end

  defp error(source) do
    assert_raise(Query.Error, fn -> run_sql(source) end).message
  end

  describe "result cap" do
    setup do
      Application.put_env(:guardian, :query_max_result_rows, 10)
      :ok
    end

    test "counts returned rows, not scanned rows", %{table: table} do
      assert error("SELECT v FROM #{table}") =~ "query result exceeds 10 rows; add a LIMIT"
      assert length(run_sql("SELECT v FROM #{table} LIMIT 10")) == 10
      assert run_sql("SELECT count(), sum(v) FROM #{table}") == [[30, 465]]
      assert length(run_sql("SELECT k, count() FROM #{table} GROUP BY k")) == 3
      assert run_sql("SELECT count() FROM #{table} WHERE v > 25") == [[5]]
      assert length(run_sql("SELECT v FROM #{table} WHERE v > 20")) == 10
    end

    test "applies to ORDER BY", %{table: table} do
      assert error("SELECT v FROM #{table} ORDER BY v") =~ "exceeds 10 rows"
      assert run_sql("SELECT v FROM #{table} ORDER BY v DESC LIMIT 2") == [[30], [29]]
      assert error("SELECT v FROM #{table} ORDER BY v LIMIT 11") =~ "LIMIT 11 exceeds the 10-row"
    end

    test "bounds bytes too", %{table: table} do
      Application.put_env(:guardian, :query_max_result_rows, 1_000)
      Application.put_env(:guardian, :query_max_result_bytes, 200)
      assert error("SELECT s FROM #{table}") =~ "query result exceeds 0 MiB"
      assert length(run_sql("SELECT s FROM #{table} LIMIT 3")) == 3
    end
  end

  describe "string functions" do
    # Strings that functions build are cut to the cap (Query.Text), never refused.
    @max Query.Text.max_bytes()

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
