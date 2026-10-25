defmodule Guardian.Query.Function.RandomTest do
  use Guardian.Query.EvaluationTestCase, async: true
  alias Guardian.Storage.Column

  test "random/0" do
    [a, b] = Guardian.Query.Evaluation.eval(snapshot([%{}, %{}]), "random()") |> Column.to_list()
    assert is_float(a) and a >= 0.0 and a <= 1.0
    assert is_float(b) and b >= 0.0 and b <= 1.0
    assert a != b
  end

  test "random/1" do
    assert eval("random(1)") == 0.019477680470628145
    assert eval("random(2)") == 0.20485249314347276

    Enum.each(1..10, fn seed ->
      value = eval("random(#{seed})")
      assert value >= 0.0 and value <= 1.0
    end)
  end
end
