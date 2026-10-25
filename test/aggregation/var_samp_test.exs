defmodule Guardian.Aggregation.VarSampTest do
  use Guardian.Query.EvaluationTestCase, async: true

  def var_samp(values) do
    eval_aggregate("var_samp(x)", Enum.map(values, &[x: &1]))
  end

  test "var_samp" do
    assert var_samp([]) == nil
    assert var_samp([4, 7, 13, 16]) === 30.0
    assert var_samp([3, 21, 98, 17, 9]) === 1510.8

    assert var_samp([4, 7, 13, 16, nil]) === 30.0
  end
end
