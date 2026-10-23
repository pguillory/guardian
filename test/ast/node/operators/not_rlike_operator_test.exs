defmodule NotRlikeOperatorTest do
  use Query.EvaluationTestCase, async: true

  test "not rlike operator" do
    assert eval("'ab' not rlike 'a'") == false
    assert eval("'ab' not rlike 'b'") == false
    assert eval("'ab' not rlike 'c'") == true
  end

  test "the pattern ends at a lower-precedence operator" do
    assert eval("'ab' not rlike 'c' and 1 = 1") == true
    assert eval("'ab' not rlike 'a' or 1 = 1") == true
  end
end
