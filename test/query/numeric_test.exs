defmodule Guardian.Query.NumericTest do
  # Targeted cases for the number rules (Guardian.Query.Numeric). `eval/2` checks each one per
  # event, over a multi-row column, and pre-evaluated; the totality grid
  # (Guardian.Query.TotalityTest) covers every function and operator more broadly.
  use Guardian.Query.EvaluationTestCase, async: true

  import Guardian.TestHelpers, only: [run_sql: 1]

  alias Guardian.Query.Function.Interval

  @max Guardian.Query.Numeric.max_int()
  @min Guardian.Query.Numeric.min_int()

  test "wrap matches two's complement" do
    assert Guardian.Query.Numeric.wrap(@max + 1) == @min
    assert Guardian.Query.Numeric.wrap(@min - 1) == @max
    assert Guardian.Query.Numeric.wrap(@max * @max) == 1
    assert Guardian.Query.Numeric.wrap(5) == 5
  end

  test "integer arithmetic wraps, per event and over columns" do
    assert eval("a + b", a: @max, b: 1) == @min
    assert eval("a - b", a: @min, b: 1) == @max
    assert eval("a * b", a: @max, b: 2) == -2
    assert eval("a * b", a: @min, b: -1) == @min
    assert eval("-a", a: @min) == @min
    assert eval("abs(a)", a: @min) == @min
    assert eval("div(a, b)", a: @min, b: -1) == @min
    assert eval("mod(a, b)", a: @min, b: -1) == 0

    # Two multi-row columns run the NIF; it must wrap the same way.
    assert eval_segment_and_rows("a + b", [%{a: @max, b: 1}, %{a: @min, b: -1}]) ==
             {[@min, @max], [@min, @max]}

    assert eval_segment_and_rows("a * b", [%{a: @max, b: @max}, %{a: @min, b: -1}]) ==
             {[1, @min], [1, @min]}
  end

  test "a float result that isn't finite is null" do
    assert eval("a + b", a: 1.0e308, b: 1.0e308) == nil
    assert eval("a * b", a: 1.0e308, b: 10) == nil
    assert eval("a / b", a: 1.0e308, b: 1.0e-308) == nil
    assert eval("exp(a)", a: 1000) == nil
    assert eval("power(a, b)", a: 10, b: 400) == nil

    assert eval_segment_and_rows("a + b", [%{a: 1.0e308, b: 1.0e308}, %{a: 1.0, b: 2}]) ==
             {[nil, 3.0], [nil, 3.0]}
  end

  test "a result with no good value is null" do
    assert eval("sqrt(a)", a: -1) == nil
    assert eval("log(a)", a: 0) == nil
    assert eval("log2(a)", a: -1) == nil
    assert eval("log10(a)", a: 0.0) == nil
    assert eval("div(a, b)", a: 1, b: 0) == nil
    assert eval("mod(a, b)", a: 1, b: 0) == nil
    assert eval("factorial(a)", a: 21) == nil
    assert eval("factorial(a)", a: 20) == 2_432_902_008_176_640_000
  end

  test "rounding a float outside int64 is null" do
    for function <- ~w[round ceil floor] do
      assert eval("#{function}(a)", a: 1.0e19) == nil
      # 9.223372036854775807e18 is 2^63 as a float, one past int64.
      assert eval("#{function}(a)", a: 9.223372036854775807e18) == nil
      assert eval("#{function}(a)", a: -9.223372036854775808e18) == @min
      assert eval("#{function}(a)", a: @max) == @max
    end
  end

  test "an interval is null when a number, a term or the total leaves int64" do
    assert Interval.eval("9223372036854775807s") == @max
    assert Interval.eval("-9223372036854775808s") == @min
    # More than 19 digits, before parsing builds a bignum.
    assert Interval.eval("99999999999999999999s") == nil
    assert Interval.eval("-0000000000000000000001s") == nil
    # A term past int64 once scaled by its unit.
    assert Interval.eval("9223372036854775807w") == nil
    # A total past int64.
    assert Interval.eval("9223372036854775807s 1s") == nil
  end

  test "date arithmetic outside years 0000 to 9999 is null" do
    assert eval("date_add(a, INTERVAL 1 DAY)", a: "9999-12-30 00:00:00") ==
             "9999-12-31 00:00:00"

    assert eval("date_add(a, INTERVAL 1 DAY)", a: "9999-12-31 00:00:00") == nil
    assert eval("date_sub(a, INTERVAL 1 DAY)", a: "0000-01-01 00:00:00") == nil
    assert eval("date_add(a, b)", a: "2026-01-01 00:00:00", b: @max) == nil
    assert eval("date_sub(a, b)", a: "2026-01-01 00:00:00", b: @min) == nil
    assert eval("a + b", a: "2026-01-01 00:00:00", b: @max) == nil
  end

  test "functions of text are null on input they can't read" do
    assert eval("ip_to_integer(a)", a: <<0xFF, 0xFE>>) == nil
    assert eval("url_port(a)", a: "http://example.com:99999999999999999999/") == nil
    assert eval("url_port(a)", a: "http://example.com:65536/") == nil
    assert eval("url_port(a)", a: "http://example.com:65535/") == 65_535
  end

  test "a list storage can't hold is null" do
    # Storage holds a list of values and a list of lists, not deeper.
    assert eval("[a]", a: [1]) == [[1]]
    assert eval("[a]", a: [[1]]) == nil
    assert eval("[[a]]", a: 1) == [[1]]
    assert eval("[[a]]", a: [1]) == nil
  end

  test "an _n aggregate of lists of lists is null, not a deeper list" do
    rows = [[x: [[1]], y: 1], [x: [[2]], y: 2]]

    for source <- ["min_n(x, 2)", "max_n(x, 2)", "min_n_by(x, y, 2)", "max_n_by(x, y, 2)"] do
      assert eval_aggregate(source, rows) == nil, source
    end

    # One list of lists is fine as a value, but not as an item of the result.
    assert eval_aggregate("max_n(x, 2)", [[x: [1]], [x: [2]]]) == [[2], [1]]
    assert eval_aggregate("max_n(x, 2)", [[x: [[1]]], [x: 2]]) == nil

    table = "numeric_max_n_#{System.unique_integer([:positive])}"
    on_exit(fn -> :ok = Guardian.Storage.delete_table(table) end)

    for {x, k} <- [{[[1]], 1}, {[[2]], 1}, {[3], 2}],
        do: :ok = Guardian.Storage.append(table, k: k, x: x)

    assert Enum.sort(run_sql("select k, max_n(x, 2), min_n_by(x, k, 2) from #{table} group by k")) ==
             [[1, nil, nil], [2, [[3]], [[3]]]]
  end

  test "comparisons near the int64 and float boundaries are exact" do
    assert eval("a < b", a: @max - 1, b: @max) == true
    assert eval("a = b", a: @max, b: @max) == true
    assert eval("a > b", a: @min + 1, b: @min) == true
    assert eval("a < b", a: 1.0e308, b: @max) == false
    assert eval("a > b", a: -1.0e308, b: @min) == false
  end

  test "a query summing past the float range answers null, not an error" do
    table = "numeric_sum_#{System.unique_integer([:positive])}"
    on_exit(fn -> :ok = Guardian.Storage.delete_table(table) end)
    for v <- [1.0e308, 1.0e308, 1.0], do: :ok = Guardian.Storage.append(table, k: 1, v: v)
    for v <- [@max, 1], do: :ok = Guardian.Storage.append(table, k: 2, v: v)

    assert Enum.sort(run_sql("select k, sum(v) from #{table} group by k")) ==
             [[1, nil], [2, @min]]
  end
end
