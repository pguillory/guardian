defmodule Guardian.Counters.AggregateTest do
  use ExUnit.Case, async: true

  alias Guardian.Counters.Aggregate

  @operators [
    {"count", 0},
    {"count", 1},
    {"count_distinct", 1},
    {"sum", 1},
    {"min", 1},
    {"max", 1},
    {"avg", 1},
  ]

  test "the allowlist contains only the v1 operators and arities" do
    assert Aggregate.operators() == @operators

    for operator <- [{"count", 2}, {"sum", 0}, {"count_if", 1}, {"SUM", 1}, :sum] do
      assert_raise ArgumentError, "unsupported counter aggregate or arity", fn ->
        Aggregate.default(operator)
      end

      assert_raise ArgumentError, fn -> Aggregate.create(operator, [1]) end
      assert_raise ArgumentError, fn -> Aggregate.merge(operator, nil, nil) end
      assert_raise ArgumentError, fn -> Aggregate.resolve(operator, nil) end
    end
  end

  test "create checks the exact argument arity" do
    for {_, arity} = operator <- @operators,
        values <- [[], [1], [1, 2]],
        length(values) != arity do
      assert_raise ArgumentError, fn -> Aggregate.create(operator, values) end
    end

    assert_raise ArgumentError, fn -> Aggregate.create({"sum", 1}, 1) end
  end

  test "empty states resolve to documented missing results" do
    for {name, _} = operator <- @operators do
      expected = if name in ["count", "count_distinct"], do: 0, else: nil
      assert Aggregate.resolve(operator, Aggregate.default(operator)) === expected
    end

    # These are states, not the query registry's already resolved empty results.
    assert Aggregate.default({"avg", 1}) === {0, 0}
    assert Aggregate.default({"sum", 1}) === nil
    assert {Hypex.Bitstring, 8, _} = Aggregate.default({"count_distinct", 1})
  end

  test "empty state is a both-sided exact identity for all supported inputs" do
    values = [nil, -3, 0, -0.0, 2.5, true, false, "x", [], [1, nil, 2]]

    for operator <- @operators, value <- values do
      empty = Aggregate.default(operator)
      single = create(operator, value)

      for state <- [empty, single, state(operator, values)] do
        assert Aggregate.merge(operator, empty, state) === state
        assert Aggregate.merge(operator, state, empty) === state
      end
    end
  end

  test "count counts events or non-null arguments, including nonnumeric arguments" do
    values = [nil, false, 0, "", [], [1]]
    assert result({"count", 0}, values) === 6
    assert result({"count", 1}, values) === 5
    assert result({"count", 1}, [nil, nil]) === 0
  end

  test "count keeps an unwrapped integer state and resolves native increments safely" do
    for operator <- [{"count", 0}, {"count", 1}] do
      max = Guardian.Query.Numeric.max_int()
      assert Aggregate.resolve(operator, max) === max
      state = Aggregate.merge(operator, max, 1)
      assert state === max + 1
      assert Aggregate.resolve(operator, state) === nil
      assert Aggregate.resolve(operator, Integer.pow(2, 2000)) === nil
    end
  end

  test "sum and average skip every nonnumeric value" do
    nonnumeric = [nil, true, false, "3", [], [2]]
    assert result({"sum", 1}, nonnumeric) === nil
    assert result({"avg", 1}, nonnumeric) === nil
    assert result({"sum", 1}, [1, 2.5 | nonnumeric]) === 3.5
    assert result({"avg", 1}, [1, 2.5 | nonnumeric]) === 1.75
    assert result({"sum", 1}, [0, nil]) === 0
  end

  test "sum wraps positive and negative integer overflow to int64" do
    max = Guardian.Query.Numeric.max_int()
    min = Guardian.Query.Numeric.min_int()
    assert result({"sum", 1}, [max, 1]) === min
    assert result({"sum", 1}, [min, -1]) === max
    assert result({"sum", 1}, [max, max, 2]) === 0
  end

  test "average preserves exact integer sums rather than wrapping" do
    max = Guardian.Query.Numeric.max_int()
    operator = {"avg", 1}
    assert state(operator, [max, max]) === {max * 2, 2}
    assert result(operator, [max, max]) === max * 1.0
    assert Aggregate.resolve(operator, {Integer.pow(2, 2000), 1}) === nil
  end

  test "average merges weighted sums and counts, not averages of bucket results" do
    operator = {"avg", 1}
    left = state(operator, [1, 2, 3, nil, "skip"])
    right = state(operator, [10])
    merged = Aggregate.merge(operator, left, right)
    assert merged === {16, 4}
    assert Aggregate.resolve(operator, merged) === 4.0
  end

  test "average ignores empty contributions without changing signed zero" do
    operator = {"avg", 1}
    prior = Aggregate.create(operator, [-0.0])
    assert prior === {-0.0, 1}

    for value <- [nil, "skip", true] do
      empty = Aggregate.create(operator, [value])
      assert Aggregate.merge(operator, prior, empty) === prior
      assert Aggregate.merge(operator, empty, prior) === prior
    end
  end

  test "float overflow absorbs later merges in both directions" do
    for operator <- [{"sum", 1}, {"avg", 1}] do
      large = Aggregate.create(operator, [1.0e308])
      overflow = Aggregate.merge(operator, large, large)
      assert overflow === :overflow
      assert Aggregate.resolve(operator, overflow) === nil

      for other <- [
            Aggregate.default(operator),
            overflow,
            create(operator, nil),
            create(operator, 2),
            create(operator, -1.0e308),
          ] do
        assert Aggregate.merge(operator, overflow, other) === :overflow
        assert Aggregate.merge(operator, other, overflow) === :overflow
      end
    end
  end

  test "min and max skip null and use the query engine's mixed term ordering" do
    for {name, expected} <- [{"min", -2}, {"max", "a"}] do
      operator = {name, 1}
      assert result(operator, [nil, "a", false, [3], 0.5, -2, nil]) === expected
      assert result(operator, [nil, nil]) === nil
    end

    assert result({"min", 1}, ["z", "a"]) === "a"
    assert result({"max", 1}, ["z", "a"]) === "z"
  end

  test "min and max numeric ties favor the right state including its type" do
    for operator <- [{"min", 1}, {"max", 1}] do
      assert Aggregate.merge(operator, 1, 1.0) === 1.0
      assert Aggregate.merge(operator, 1.0, 1) === 1
    end
  end

  test "unchanged contributions are detectable by exact state comparison before CAS" do
    cases = [
      {{"count", 1}, 5, nil},
      {{"sum", 1}, 5, nil},
      {{"sum", 1}, 5, "skip"},
      {{"sum", 1}, 5, 0},
      {{"min", 1}, 5, 8},
      {{"min", 1}, 5, 5},
      {{"max", 1}, 5, 3},
      {{"max", 1}, 5, 5},
      {{"avg", 1}, {5, 1}, false},
    ]

    for {operator, prior, value} <- cases do
      assert Aggregate.merge(operator, prior, create(operator, value)) === prior
    end

    operator = {"count_distinct", 1}
    prior = state(operator, ["already present", 7])
    assert Aggregate.merge(operator, prior, create(operator, "already present")) === prior
    assert Aggregate.merge(operator, prior, prior) === prior
  end

  test "distinct skips null, deduplicates values and distinguishes numeric types" do
    operator = {"count_distinct", 1}
    assert result(operator, [nil, nil]) === 0
    assert result(operator, ["a", nil, "a", "b", "b"]) === 2
    assert result(operator, [1, 1.0]) === 2

    for value <- [true, false, "a", [1]] do
      assert result(operator, [nil, value, value]) === 1
    end
  end

  test "real updates change the state so a bucket caller can detect a needed write" do
    cases = [
      {{"count", 0}, 5, nil},
      {{"count", 1}, 5, "count me"},
      {{"sum", 1}, 5, 2},
      {{"min", 1}, 5, 3},
      {{"max", 1}, 5, 8},
      {{"avg", 1}, {5, 1}, 2},
      {{"count_distinct", 1}, state({"count_distinct", 1}, ["a"]), "b"},
    ]

    for {operator, prior, value} <- cases do
      refute Aggregate.merge(operator, prior, create(operator, value)) === prior
    end
  end

  test "distinct stays precision 8 and fixed size with representative cardinality error" do
    operator = {"count_distinct", 1}
    assert {Hypex.Bitstring, 8, empty} = Aggregate.default(operator)
    assert byte_size(empty) == 256

    for n <- [1, 100, 1000, 10_000] do
      sketch = state(operator, Enum.to_list(1..n))
      assert {Hypex.Bitstring, 8, registers} = sketch
      assert byte_size(registers) == 256
      estimate = Aggregate.resolve(operator, sketch)
      assert abs(estimate - n) <= max(1, n * 0.25), "cardinality #{n}: #{estimate}"
    end
  end

  test "partitioned merging agrees with sequential merging for every operator" do
    values = [nil, 1, 2, 3, true, "a", 2, [1], 2.5, nil, -2]

    for operator <- @operators do
      sequential = state(operator, values)

      for size <- [1, 2, 3, 7, 30] do
        partitioned =
          values
          |> Enum.chunk_every(size)
          |> Enum.map(&state(operator, &1))
          |> Enum.reduce(Aggregate.default(operator), &Aggregate.merge(operator, &2, &1))

        assert_result_equal(
          Aggregate.resolve(operator, partitioned),
          Aggregate.resolve(operator, sequential)
        )

        if operator == {"count_distinct", 1}, do: assert(partitioned === sequential)
      end
    end
  end

  test "merge is associative for normal-range values within floating point tolerance" do
    for operator <- @operators do
      for [a, b, c] <- [[1, 2, 3], [nil, 2, 3], [0.1, 0.2, 0.3], ["a", false, [1]], [1, 1.0, 1]] do
        [a, b, c] = Enum.map([a, b, c], &create(operator, &1))
        left = Aggregate.merge(operator, Aggregate.merge(operator, a, b), c)
        right = Aggregate.merge(operator, a, Aggregate.merge(operator, b, c))
        assert_result_equal(Aggregate.resolve(operator, left), Aggregate.resolve(operator, right))
      end
    end
  end

  test "integer sum merging is associative even when modular arithmetic wraps" do
    operator = {"sum", 1}
    max = Guardian.Query.Numeric.max_int()
    left = Aggregate.merge(operator, Aggregate.merge(operator, max, max), 3)
    right = Aggregate.merge(operator, max, Aggregate.merge(operator, max, 3))
    assert left === right
    assert left === 1
  end

  test "counter defaults and precision do not change query aggregate contracts" do
    assert Guardian.Aggregation.Sum.default() === 0.0
    assert Guardian.Aggregation.Avg.default() === nil
    assert {Hypex.Array, 14, _} = Guardian.Aggregation.CountDistinct.start(nil)
  end

  defp create({"count", 0} = operator, _value) do
    Aggregate.create(operator, [])
  end

  defp create(operator, value) do
    Aggregate.create(operator, [value])
  end

  defp state(operator, values) do
    Enum.reduce(values, Aggregate.default(operator), fn value, prior ->
      Aggregate.merge(operator, prior, create(operator, value))
    end)
  end

  defp result(operator, values) do
    Aggregate.resolve(operator, state(operator, values))
  end

  defp assert_result_equal(left, right) when is_float(left) and is_float(right) do
    assert_in_delta left, right, 1.0e-12
  end

  defp assert_result_equal(left, right) do
    assert(left === right)
  end
end
