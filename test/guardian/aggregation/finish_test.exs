defmodule Guardian.Aggregation.FinishTest do
  use ExUnit.Case, async: true

  alias Guardian.Aggregation
  alias Guardian.Storage.Value

  @top_n ~w[min_n max_n min_n_by max_n_by]

  test "top-N list validity is checked at the final depth, preserving valid bytes" do
    # The storage limit counts the scalar layer as well as list layers.
    valid_item = nest(-0.0, Value.max_list_depth() - 2)
    too_deep_item = nest(-0.0, Value.max_list_depth() - 1)

    # Both inputs fit on their own; wrapping the latter in a result list does not.
    assert Value.valid?(valid_item)
    assert Value.valid?(too_deep_item)

    for name <- @top_n do
      aggregation = Aggregation.fetch!(name)
      state = top_n_state(aggregation, name, [valid_item], 2)
      result = Aggregation.finish(aggregation, state)
      assert :erlang.term_to_binary(result) == :erlang.term_to_binary([valid_item]), name

      for values <- [[too_deep_item], [1, too_deep_item]] do
        state = top_n_state(aggregation, name, values, 2)
        assert Aggregation.finish(aggregation, state) === nil, name
      end
    end
  end

  test "selected list results retain their bytes in both callback dispatch forms" do
    value = nest([nil, -0.0, 1, 1.0, "x"], Value.max_list_depth() - 2)

    selections =
      for name <- ~w[arbitrary min max min_by max_by] do
        args = if String.ends_with?(name, "_by"), do: [value, 1], else: [value]
        {Aggregation.fetch!(name), args}
      end

    counters = for name <- ~w[min max], do: {Aggregation.fetch_counter!({name, 1}), [value]}

    for {aggregation, args} <- selections ++ counters do
      result = Aggregation.finish(aggregation, Aggregation.start(aggregation, args))
      assert :erlang.term_to_binary(result) == :erlang.term_to_binary(value)
    end
  end

  test "empty top-N lists remain distinct from no-row defaults" do
    for name <- @top_n, n <- [0, 2] do
      aggregation = Aggregation.fetch!(name)
      # A null ordering key skips the _by row; plain top-N skips its null value.
      args = if String.ends_with?(name, "_by"), do: [nil, nil, n], else: [nil, n]
      state = Aggregation.start(aggregation, args)
      assert Aggregation.finish(aggregation, state) === [], name
      assert Aggregation.default(aggregation) === nil, name
    end
  end

  test "invalid selected list states are nulled through both dispatch forms" do
    # Normal inputs are validated before aggregation. Inject an invalid list to
    # pin the shared boundary even for callbacks that only select an input.
    invalid = nest(1, Value.max_list_depth())

    for name <- ~w[arbitrary min max] do
      assert Aggregation.finish(Aggregation.fetch!(name), invalid) === nil, name
    end
  end

  test "scalar count policies remain in callbacks" do
    beyond_int64 = Guardian.Query.Numeric.max_int() + 1

    for name <- ~w[count count_if] do
      assert Aggregation.finish(Aggregation.fetch!(name), beyond_int64) === beyond_int64
    end

    for arity <- [0, 1] do
      assert Aggregation.finish(Aggregation.fetch_counter!({"count", arity}), beyond_int64) ===
               nil
    end
  end

  defp top_n_state(aggregation, name, values, n) do
    values
    |> Enum.with_index()
    |> Enum.map(fn {value, order} ->
      args = if String.ends_with?(name, "_by"), do: [value, order, n], else: [value, n]
      Aggregation.start(aggregation, args)
    end)
    |> Enum.reduce(&Aggregation.merge(aggregation, &1, &2))
  end

  defp nest(value, 0) do
    value
  end

  defp nest(value, depth) do
    nest([value], depth - 1)
  end
end
