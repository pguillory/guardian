defmodule Query.Function.IfTest do
  use Query.EvaluationTestCase, async: true

  test "if function" do
    assert eval("if(null, 1, 2)") === nil
    assert eval("if(false, 1, 2)") === 2
    assert eval("if(true, 1, 2)") === 1
    assert eval("if(123, 1, 2)") === nil
    assert eval("if(4.5, 1, 2)") === nil
    assert eval("if('a', 1, 2)") === nil

    assert eval("if(x, 1, 2)", x: true) === 1
    assert eval("if(x, 1, 2)", x: false) === 2
    assert eval("if(x, 1, 2)", x: nil) === nil
  end
end
