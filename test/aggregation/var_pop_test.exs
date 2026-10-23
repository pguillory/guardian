defmodule Aggregation.VarPopTest do
  use Query.EvaluationTestCase, async: true

  def var_pop(values) do
    eval_aggregate("var_pop(x)", Enum.map(values, &[x: &1]))
  end

  test "var_pop" do
    assert var_pop([]) == nil
    assert var_pop([4, 7, 13, 16]) === 22.5
    assert var_pop([21, 42, 37, 16, 31, 28, 33, 41, 12]) === 102.22222222222223

    assert var_pop([4, 7, 13, 16, nil]) === 22.5
  end
end
