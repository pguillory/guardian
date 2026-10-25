defmodule Guardian.Query.EvaluationTest do
  import Guardian.Query.Evaluation
  use ExUnit.Case, async: true

  test "pre_eval" do
    assert pre_eval("1 + 2") == "3"
    assert pre_eval("x + (1 + 2)") == "x + 3"
    assert pre_eval("(1 + 2) + x") == "3 + x"
    assert pre_eval("(1 + 2 + 3) + (x + 4 + 5)") == "6 + (x + 4 + 5)"
    assert pre_eval("(1 + 2 + 3) + (x + (4 + 5))") == "6 + (x + 9)"
    assert pre_eval("(1 + 2) + now()") == "3 + now()"
    assert pre_eval("(1 + 2) + random()") == "3 + random()"
    assert pre_eval("(1 + 2) + abs(-5)") == "8"
    assert pre_eval("random() < 0.5") == "random() < 0.5"
    assert pre_eval("random('foo') < 0.5") == "true"
  end

  describe "Guardian.Query.Eval" do
    test "evaluates a rewrite-only node through its rewrite" do
      assert eval("(1 + 2) > 2") == true
      assert eval(%{"x" => 3}, "x BETWEEN 1 AND 5") == true
      assert Guardian.Query.EvaluationTestCase.eval("x BETWEEN 1 AND 5", x: 3) == true
    end

    test "raises Guardian.Query.Error for a node that is not an expression" do
      assert_raise Guardian.Query.Error, "* cannot be evaluated as an expression", fn ->
        Guardian.Query.Eval.eval(%Guardian.AST.Node.Splat{}, %{})
      end
    end
  end
end
