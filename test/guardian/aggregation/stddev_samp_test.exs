defmodule Guardian.Aggregation.StddevSampTest do
  use Guardian.Query.EvaluationTestCase, async: true

  def stddev_samp(values) do
    eval_aggregate("stddev_samp(x)", Enum.map(values, &[x: &1]))
  end

  test "stddev_samp" do
    assert stddev_samp([]) == nil
    assert_in_delta stddev_samp([4, 7, 13, 16]), 5.477225575051661, 1.0e-9
    assert_in_delta stddev_samp([3, 21, 98, 17, 9]), 38.86901079266104, 1.0e-9

    assert_in_delta stddev_samp([4, 7, 13, 16, nil]), 5.477225575051661, 1.0e-9
  end
end
