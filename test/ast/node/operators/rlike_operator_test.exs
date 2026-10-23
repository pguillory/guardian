defmodule RlikeOperatorTest do
  use Query.EvaluationTestCase, async: true

  test "rlike operator" do
    assert eval("'ab' rlike 'a'") == true
    assert eval("'ab' rlike 'b'") == true
    assert eval("'ab' rlike 'c'") == false
  end

  test "the pattern ends at a lower-precedence operator" do
    assert eval("'ab' rlike 'a' and 1 = 1") == true
    assert eval("'ab' rlike 'c' or 1 = 1") == true
    assert eval("'ab' rlike 'a' = true") == true
  end
end
