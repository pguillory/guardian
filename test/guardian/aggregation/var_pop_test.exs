defmodule Guardian.Aggregation.VarPopTest do
  use Guardian.Query.EvaluationTestCase, async: true

  def var_pop(values) do
    eval_aggregate("var_pop(x)", Enum.map(values, &[x: &1]))
  end

  test "var_pop" do
    assert var_pop([]) == nil
    assert_in_delta var_pop([4, 7, 13, 16]), 22.5, 1.0e-9
    assert_in_delta var_pop([21, 42, 37, 16, 31, 28, 33, 41, 12]), 102.22222222222223, 1.0e-9

    assert_in_delta var_pop([4, 7, 13, 16, nil]), 22.5, 1.0e-9
  end

  test "var_pop is null once the moments overflow, however later rows merge in" do
    assert var_pop([1.0e308, -1.0e308]) == nil
    assert var_pop([1.0e308, -1.0e308, 1, 2]) == nil
  end
end
