defmodule Guardian.Aggregation.CounterContractTest do
  use ExUnit.Case, async: true

  alias Guardian.Aggregation
  alias Guardian.Counters.Aggregate

  test "counter registration opts into shared implementations and exact arities" do
    assert Aggregation.counter_operators() == Aggregate.operators()

    for {name, _arity} = operator <- Aggregate.operators() do
      assert operator in Aggregation.names_and_arities()
      counter = Aggregation.fetch_counter!(operator)
      query = Aggregation.fetch!(name)

      module = fn
        {implementation, _option} -> implementation
        implementation -> implementation
      end

      assert module.(counter) == module.(query)
    end

    for operator <- Aggregation.names_and_arities() -- Aggregate.operators() do
      assert_raise ArgumentError, fn -> Aggregation.fetch_counter!(operator) end
    end

    for values <- [nil, 1, {}, %{}, [1 | 2]] do
      assert_raise ArgumentError, fn -> Aggregate.create({"sum", 1}, values) end
    end
  end

  test "query empty results remain distinct from counter empty states" do
    for {name, query_default, counter_empty} <- [
          {"sum", 0.0, nil},
          {"avg", nil, {0, 0}},
        ] do
      assert Aggregation.default(Aggregation.fetch!(name)) === query_default
      assert Aggregation.empty(Aggregation.fetch_counter!({name, 1})) === counter_empty
    end

    query = Aggregation.fetch!("count_distinct")
    counter = Aggregation.fetch_counter!({"count_distinct", 1})
    assert Aggregation.default(query) === 0
    assert {Hypex.Array, 14, _} = Aggregation.start(query, [nil])
    assert {Hypex.Bitstring, 8, registers} = Aggregation.empty(counter)
    assert byte_size(registers) == 256
  end

  test "count query results stay raw while counter results apply int64 bounds" do
    query = Aggregation.fetch!("count")
    counter = Aggregation.fetch_counter!({"count", 0})
    beyond_int64 = Guardian.Query.Numeric.max_int() + 1

    assert Aggregation.start(query, []) === 1
    assert Aggregation.start(counter, []) === 1
    assert Aggregation.start(query, [nil]) === 0
    assert Aggregation.start(Aggregation.fetch_counter!({"count", 1}), [false]) === 1
    assert Aggregation.finish(query, beyond_int64) === beyond_int64
    assert Aggregation.finish(counter, beyond_int64) === nil
  end

  test "counter average empty merges preserve float bits while queries retain arithmetic" do
    query = Aggregation.fetch!("avg")
    counter = Aggregation.fetch_counter!({"avg", 1})
    negative_zero = Aggregation.start(counter, [-0.0])
    empty = Aggregation.empty(counter)

    for merged <- [
          Aggregation.merge(counter, empty, negative_zero),
          Aggregation.merge(counter, negative_zero, empty),
        ] do
      assert {sum, 1} = merged
      assert <<sum::float>> == <<-0.0::float>>
      result = Aggregation.finish(counter, merged)
      assert <<result::float>> == <<-0.0::float>>
    end

    assert {sum, 1} = Aggregation.merge(query, negative_zero, empty)
    assert <<sum::float>> == <<0.0::float>>

    for {left, right} <- [{empty, :overflow}, {:overflow, empty}] do
      assert Aggregation.merge(counter, left, right) === :overflow
      assert Aggregation.merge(query, left, right) === :overflow
    end
  end
end
