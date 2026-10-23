defmodule Query.LimitsTest do
  # Changes limits in the application environment, so not async.
  use ExUnit.Case, async: false
  import TestHelpers, only: [run_sql: 1]

  @keys [:query_max_result_rows, :query_max_result_bytes, :query_max_string_bytes]

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
    test "lpad and rpad refuse huge sizes" do
      assert error("SELECT lpad('x', 2000000000)") =~
               "lpad would build a string of 2000000000 bytes"

      assert error("SELECT rpad('x', 2000000000)") =~ "rpad would build a string"
      assert run_sql("SELECT lpad('x', 3), rpad('x', 3)") == [["  x", "x  "]]
    end

    test "lpad and rpad count bytes, not characters, against the cap" do
      Application.put_env(:guardian, :query_max_string_bytes, 10)

      # é is two bytes: three of them padded to 7 characters is 10 bytes, to 8 is 11.
      assert run_sql("SELECT lpad('ééé', 7), rpad('ééé', 7)") == [["    ééé", "ééé    "]]
      assert error("SELECT lpad('ééé', 8)") =~ "lpad would build a string of 11 bytes"
      assert error("SELECT rpad('ééé', 10)") =~ "rpad would build a string of 13 bytes"

      # An input already over the cap is refused only if padding would grow it.
      assert run_sql("SELECT lpad('12345678901', 2)") == [["12345678901"]]
      assert error("SELECT rpad('12345678901', 12)") =~ "rpad would build a string of 12 bytes"
    end

    test "concat, ||, and replace refuse results over the cap", %{table: table} do
      Application.put_env(:guardian, :query_max_string_bytes, 10)

      assert error("SELECT concat('123456', '78901')") =~
               "concat would build a string of 11 bytes"

      assert error("SELECT '123456' || '78901'") =~ "concat would build"
      assert error("SELECT concat('1234', '5678', '90', '1')") =~ "concat"
      assert run_sql("SELECT concat('12345', '67890')") == [["1234567890"]]
      assert error("SELECT replace(s, 'r', 'xxxx') FROM #{table}") =~ "replace (worst case)"
      assert run_sql("SELECT replace('ab', 'a', 'c')") == [["cb"]]
    end
  end

  test "factorial refuses results that do not fit in 64 bits" do
    assert error("SELECT factorial(100000000)") =~ "factorial(100000000) does not fit"
    assert error("SELECT factorial(21)") =~ "the largest is factorial(20)"

    assert run_sql("SELECT factorial(0), factorial(5), factorial(20)") == [
             [1, 120, 2_432_902_008_176_640_000],
           ]
  end
end
