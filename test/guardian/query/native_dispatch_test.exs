defmodule Guardian.Query.NativeDispatchTest do
  use ExUnit.Case, async: true
  import Guardian.Query.NativeDispatch

  alias Guardian.Query.Constant
  alias Guardian.Query.Evaluation
  alias Guardian.Storage.Column

  test "numeric and boolean columns use the registered native callbacks" do
    left = Column.from_list([2, 6, nil])
    right = Column.from_list([3, 2, 4])

    for {operation, expected} <- [
          add: [5, 8, nil],
          subtract: [-1, 4, nil],
          multiply: [6, 12, nil],
          divide: [2 / 3, 3.0, nil],
        ] do
      assert values(evaluate(operation, left, right, &scalar/2)) === expected
    end

    left = Column.from_list([true, false, nil])
    right = Column.from_list([false, true, true])
    assert values(evaluate(:and, left, right, &scalar/2)) == [false, false, nil]
    assert values(evaluate(:or, left, right, &scalar/2)) == [true, true, true]
    assert values(evaluate(:not, left, &scalar/1)) == [false, true, nil]
    assert values(evaluate(:to_boolean, left, &scalar/1)) == [true, false, nil]
  end

  test "constants on either side keep the scalar path for every operation" do
    constant = Constant.duplicate(2, 2)
    column = Column.from_list([1, nil])

    for operation <- [:add, :subtract, :multiply, :divide, :and, :or],
        {left, right} <- [{constant, column}, {column, constant}, {constant, constant}] do
      assert values(evaluate(operation, left, right, &scalar/2)) ==
               ["scalar", "scalar"]
    end

    for operation <- [:not, :to_boolean, :to_string] do
      assert evaluate(operation, constant, &scalar/1) ==
               Constant.duplicate("scalar", 2)
    end
  end

  test "timestamp metadata selects scalar addition in both directions, subtraction on the left" do
    strings = Column.from_list(["not even a timestamp", nil])
    ints = Column.from_list([1, 2])

    for {operation, left, right} <- [
          {:add, strings, ints},
          {:add, ints, strings},
          {:subtract, strings, ints},
        ] do
      assert values(evaluate(operation, left, right, &scalar/2)) ==
               ["scalar", "scalar"]
    end

    assert values(evaluate(:subtract, ints, strings, &scalar/2)) == [nil, nil]

    # Only top-level strings/integers select timestamp arithmetic, not list items
    # or float seconds. The old column-wide test does not require matching rows.
    lists = Column.from_list([["2026-01-01 00:00:00"], nil])
    floats = Column.from_list([1.0, 2.0])
    assert values(evaluate(:add, lists, ints, &scalar/2)) == [nil, nil]
    assert values(evaluate(:add, strings, floats, &scalar/2)) == [nil, nil]

    ints = Column.from_list([nil, 2])

    assert values(evaluate(:add, strings, ints, &scalar/2)) ==
             ["scalar", "scalar"]
  end

  test "only string/null columns take the native string identity path" do
    long = String.duplicate("é", Guardian.Query.Text.max_bytes())
    column = Column.from_list([long, nil, <<255>>])
    result = evaluate(:to_string, column, &scalar/1)
    assert result === column

    for input <- [[1, nil], [["x"], nil], [true, "x"]] do
      assert values(evaluate(:to_string, Column.from_list(input), &scalar/1)) ==
               ["scalar", "scalar"]
    end
  end

  test "empty inputs preserve normalization and scalar constant evaluation" do
    empty = Column.from_list([])
    assert evaluate(:add, empty, empty, &scalar/2) == Constant.duplicate(nil, 0)
    assert evaluate(:to_string, empty, &scalar/1) == Constant.duplicate(nil, 0)

    assert evaluate(:to_string, Constant.duplicate(1, 0), &scalar/1) ==
             Constant.duplicate("scalar", 0)
  end

  test "mutable columns retain numeric native dispatch and string identity" do
    left = Column.duplicate(2, 2)
    right = Column.duplicate(3, 2)
    assert values(evaluate(:add, left, right, &scalar/2)) == [5, 5]

    strings = Column.duplicate("x", 2)
    assert evaluate(:to_string, strings, &scalar/1) === strings
  end

  test "constant/column count mismatches still fail" do
    for {left, right} <- [
          {Constant.duplicate(1, 1), Column.from_list([1, 2])},
          {Column.from_list([1, 2]), Constant.duplicate(1, 1)},
        ] do
      assert_raise MatchError, fn ->
        evaluate(:add, left, right, &scalar/2)
      end
    end
  end

  test "AND and OR still skip an unreachable right operand" do
    assert Evaluation.eval("false AND test_raise(1)") === false
    assert Evaluation.eval("true OR test_raise(1)") === true
  end

  test "unknown operations fail loudly" do
    constant = Constant.duplicate(1, 1)
    # Keep the invalid operation dynamic to avoid a never-matches type warning.
    operation = String.to_existing_atom("unknown")

    assert_raise FunctionClauseError, fn ->
      evaluate(operation, constant, &scalar/1)
    end

    assert_raise FunctionClauseError, fn ->
      evaluate(operation, constant, constant, &scalar/2)
    end
  end

  defp scalar(_) do
    "scalar"
  end

  defp scalar(_, _) do
    "scalar"
  end

  defp values(%Constant{value: value, count: count}) do
    List.duplicate(value, count)
  end

  defp values(column) do
    Column.to_list(column)
  end
end
