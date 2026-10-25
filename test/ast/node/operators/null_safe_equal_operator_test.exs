defmodule Guardian.NullSafeEqualOperatorTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "null safe equal operator" do
    assert eval("1 <=> 2") == false
    assert eval("1 <=> 1") == true
    assert eval("2 <=> 1") == false

    assert eval("1.0 <=> 2.0") == false
    assert eval("1.0 <=> 1.0") == true
    assert eval("2.0 <=> 1.0") == false

    assert eval("1.0 <=> 2") == false
    assert eval("1.0 <=> 1") == true
    assert eval("2.0 <=> 1") == false

    assert eval("1 <=> 2.0") == false
    assert eval("1 <=> 1.0") == true
    assert eval("2 <=> 1.0") == false

    assert eval("nil <=> 2") == false
    assert eval("nil <=> nil") == true
    assert eval("2 <=> nil") == false
  end
end
