defmodule Guardian.NotRlikeOperatorTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "not rlike operator" do
    assert eval("'ab' not rlike 'a'") == false
    assert eval("'ab' not rlike 'b'") == false
    assert eval("'ab' not rlike 'c'") == true
  end

  test "the pattern ends at a lower-precedence operator" do
    assert eval("'ab' not rlike 'c' and 1 = 1") == true
    assert eval("'ab' not rlike 'a' or 1 = 1") == true
  end

  test "not rlike with a quantified pattern" do
    assert eval("'/u/123' not rlike '[0-9]+'") == false
    assert eval("'/u/' not rlike '[0-9]+'") == true
    assert eval("null not rlike 'a'") == nil
  end
end
