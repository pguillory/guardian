defmodule Guardian.Aggregation.CounterContractTest do
  # Queries and counters share one registry and one configuration per aggregate.
  use ExUnit.Case, async: true

  alias Guardian.Aggregation

  # The result of every aggregate over no rows: a query's empty-input default and a
  # counter's missing or failed result.
  @no_rows %{
    {"count", 0} => 0,
    {"count", 1} => 0,
    {"count_if", 1} => 0,
    {"count_distinct", 1} => 0,
    {"all", 1} => true,
  }

  test "every registered name and arity has a pinned no-rows result" do
    assert Map.keys(@no_rows) -- Aggregation.names_and_arities() == []

    for {name, _arity} = operator <- Aggregation.names_and_arities() do
      aggregation = Aggregation.fetch!(name)
      expected = Map.get(@no_rows, operator)
      assert Aggregation.default(aggregation) === expected, name
      assert Aggregation.finish(aggregation, Aggregation.empty(aggregation)) === expected, name
    end
  end

  test "the empty state is an exact identity on both sides for every aggregate" do
    values = [nil, -3, 0, -0.0, 2.5, true, false, "x", [], [1, nil, 2]]

    for {name, arity} <- Aggregation.names_and_arities() do
      aggregation = Aggregation.fetch!(name)
      empty = Aggregation.empty(aggregation)

      singles =
        Enum.map(
          values,
          &Aggregation.start(aggregation, Guardian.Test.Aggregation.args(name, arity, &1))
        )

      merged = Enum.reduce(singles, &Aggregation.merge(aggregation, &1, &2))

      for state <- [empty, merged | singles] do
        assert Aggregation.merge(aggregation, empty, state) === state, name
        assert Aggregation.merge(aggregation, state, empty) === state, name
      end
    end
  end

  test "arbitrary distinguishes no rows from a real null" do
    aggregation = Aggregation.fetch!("arbitrary")
    empty = Aggregation.empty(aggregation)
    null = Aggregation.start(aggregation, [nil])

    refute empty === null
    assert Aggregation.merge(aggregation, empty, null) === null
    assert Aggregation.merge(aggregation, null, Aggregation.start(aggregation, [1])) === null
    assert Aggregation.merge(aggregation, empty, Aggregation.start(aggregation, [1])) === 1
    assert Aggregation.finish(aggregation, null) === nil
    assert Aggregation.finish(aggregation, empty) === nil
  end

  test "top-N empty states merge with any n, and disagreeing real states raise" do
    for {name, args} <- [
          {"min_n", fn n -> [1, n] end},
          {"max_n", fn n -> [1, n] end},
          {"min_n_by", fn n -> ["a", 1, n] end},
          {"max_n_by", fn n -> ["a", 1, n] end},
        ] do
      aggregation = Aggregation.fetch!(name)
      empty = Aggregation.empty(aggregation)
      two = Aggregation.start(aggregation, args.(2))
      three = Aggregation.start(aggregation, args.(3))

      assert Aggregation.merge(aggregation, empty, two) === two
      assert Aggregation.merge(aggregation, three, empty) === three
      assert Aggregation.finish(aggregation, two) == [Enum.at(args.(2), 0)]
      assert Aggregation.finish(aggregation, Aggregation.start(aggregation, args.(0))) == []

      assert_raise Guardian.Query.Error, ~r/n must be the same/, fn ->
        Aggregation.merge(aggregation, two, three)
      end
    end
  end

  test "count_distinct uses one precision-8 bitstring sketch" do
    aggregation = Aggregation.fetch!("count_distinct")
    assert {Hypex.Bitstring, 8, registers} = Aggregation.empty(aggregation)
    assert byte_size(registers) == 256
    assert {Hypex.Bitstring, 8, _} = Aggregation.start(aggregation, ["x"])
    assert Aggregation.start(aggregation, [nil]) === Aggregation.empty(aggregation)
  end

  test "sum over no rows is null" do
    assert Aggregation.default(Aggregation.fetch!("sum")) === nil
  end

  test "count results are raw; storage boundaries refuse integers outside int64" do
    beyond_int64 = Guardian.Query.Numeric.max_int() + 1

    for arity <- [0, 1] do
      aggregation = Aggregation.fetch!("count")
      assert Aggregation.start(aggregation, List.duplicate(nil, arity)) === 1 - arity
      assert Aggregation.finish(aggregation, beyond_int64) === beyond_int64
    end

    refute Guardian.Storage.Value.valid?(beyond_int64)
  end

  test "average empty merges preserve float bits" do
    aggregation = Aggregation.fetch!("avg")
    negative_zero = Aggregation.start(aggregation, [-0.0])

    for empty <- [Aggregation.empty(aggregation), Aggregation.start(aggregation, [nil])] do
      for merged <- [
            Aggregation.merge(aggregation, empty, negative_zero),
            Aggregation.merge(aggregation, negative_zero, empty),
          ] do
        assert {sum, 1} = merged
        assert <<sum::float>> == <<-0.0::float>>
        result = Aggregation.finish(aggregation, merged)
        assert <<result::float>> == <<-0.0::float>>
      end

      for {left, right} <- [{empty, :overflow}, {:overflow, empty}] do
        assert Aggregation.merge(aggregation, left, right) === :overflow
      end
    end
  end
end
