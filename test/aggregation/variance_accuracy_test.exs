defmodule Aggregation.VarianceAccuracyTest do
  # Shared cases for var_pop, var_samp, stddev_pop and stddev_samp, which keep the
  # same {count, mean, m2} accumulator.
  use Query.EvaluationTestCase, async: true

  @names ["var_pop", "var_samp", "stddev_pop", "stddev_samp"]

  defp agg(name, values) do
    eval_aggregate("#{name}(x)", Enum.map(values, &[x: &1]))
  end

  defp assert_close(actual, expected) do
    assert is_float(actual), "expected #{expected}, got #{inspect(actual)}"

    assert abs(actual - expected) <= 1.0e-9 * max(1.0, abs(expected)),
           "expected #{expected}, got #{actual}"
  end

  # A sum of squares minus the squared mean cancels here: it went slightly negative,
  # so stddev raised taking its square root and var_pop came back negative.
  test "nearly equal values give exactly zero" do
    for name <- @names, value <- [0.1, 0.3, 3.3, 123.456, 1.0e10 + 0.1] do
      assert agg(name, List.duplicate(value, 7)) === 0.0
    end
  end

  # The old formula returned 0.0 for var_pop here (true 1.25).
  test "values far from zero" do
    values = Enum.map(1..4, &(1.0e9 + &1))
    assert_close(agg("var_pop", values), 1.25)
    assert_close(agg("var_samp", values), 5 / 3)
    assert_close(agg("stddev_pop", values), :math.sqrt(1.25))
    assert_close(agg("stddev_samp", values), :math.sqrt(5 / 3))
  end

  test "values that are not numbers are skipped" do
    for name <- @names do
      assert agg(name, [4, "a", 7, true, 13, nil, [1], 16]) === agg(name, [4, 7, 13, 16])
      assert agg(name, ["a", nil]) == nil
    end
  end

  # Partial accumulators merge in any grouping (segments, partitions, machines).
  test "merge is associative, with empty accumulators on either side" do
    for name <- @names do
      agg = Aggregation.fetch!(name)
      merge = &Aggregation.merge(agg, &1, &2)
      [a, b, c] = Enum.map([[4, 7], [13], [16, 21, 2]], &accumulate(agg, &1))
      empty = Aggregation.start(agg, [nil])
      expected = Aggregation.finish(agg, merge.(merge.(a, b), c))

      for acc <- [
            merge.(a, merge.(b, c)),
            merge.(merge.(c, a), b),
            merge.(empty, merge.(merge.(a, b), c)),
            merge.(merge.(merge.(a, empty), b), merge.(c, empty)),
          ] do
        assert_close(Aggregation.finish(agg, acc), expected)
      end

      assert Aggregation.finish(agg, merge.(empty, empty)) == nil
    end
  end

  # Two multi-row partials merged, checked against known answers: small values, and
  # uneven partials sharing a large offset.
  test "merged partials give the known result" do
    merged = fn name, values1, values2 ->
      agg = Aggregation.fetch!(name)
      acc = Aggregation.merge(agg, accumulate(agg, values1), accumulate(agg, values2))
      Aggregation.finish(agg, acc)
    end

    assert_close(merged.("var_pop", [4, 7, 13], [16, 21, 2]), 45.583333333333336)
    assert_close(merged.("var_samp", [4, 7, 13], [16, 21, 2]), 54.7)

    offset = Enum.map(1..4, &(1.0e9 + &1))
    assert_close(merged.("var_pop", Enum.take(offset, 1), Enum.drop(offset, 1)), 1.25)
    assert_close(merged.("var_samp", Enum.take(offset, 3), Enum.drop(offset, 3)), 5 / 3)
  end

  test "sample variance and deviation need two numbers" do
    for name <- ["var_samp", "stddev_samp"] do
      assert agg(name, [5]) == nil
      assert agg(name, [5, nil, "a"]) == nil
    end

    assert agg("var_pop", [5]) === 0.0
  end

  defp accumulate(agg, values) do
    values
    |> Enum.map(&Aggregation.start(agg, [&1]))
    |> Enum.reduce(&Aggregation.merge(agg, &1, &2))
  end
end
