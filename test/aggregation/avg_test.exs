defmodule Guardian.Aggregation.AvgTest do
  use Guardian.Query.EvaluationTestCase, async: true

  def avg(values) do
    eval_aggregate("avg(x)", Enum.map(values, &[x: &1]))
  end

  test "avg" do
    assert avg([]) == nil
    assert avg([1, 2]) == 1.5
    assert avg([1, nil, 2]) == 1.5
  end

  test "avg skips values that are not numbers" do
    assert avg([1, "a", 3]) == 2.0
    assert avg([1, true, [4], 3]) == 2.0
    assert avg(["a", false]) == nil
  end

  test "avg of large integers is exact, and a float overflow is null" do
    max = Guardian.Query.Numeric.max_int()
    assert avg([max, max]) == max * 1.0
    assert avg([1.0e308, 1.0e308]) == nil
    assert avg([1.0e308, 1.0e308, -1.0e308, 1]) == nil
  end
end
