defmodule Guardian.Aggregation.StddevPopTest do
  use Guardian.Query.EvaluationTestCase, async: true

  def stddev_pop(values) do
    eval_aggregate("stddev_pop(x)", Enum.map(values, &[x: &1]))
  end

  test "stddev_pop" do
    assert stddev_pop([]) == nil
    assert stddev_pop([4, 7, 13, 16]) === 4.743416490252569
    assert stddev_pop([21, 42, 37, 16, 31, 28, 33, 41, 12]) === 10.110500592068734

    assert stddev_pop([4, 7, 13, 16, nil]) === 4.743416490252569
  end
end
