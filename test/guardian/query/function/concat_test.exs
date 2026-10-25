defmodule Guardian.Query.Function.ConcatTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "concat function" do
    assert eval("concat('a', 'b')") === "ab"
    assert eval("concat('a', null)") === "a"
    assert eval("concat(null, 'b')") === "b"
    assert eval("concat(null, null)") === ""

    assert eval("concat('a', 'b', 'c')") === "abc"
    assert eval("concat('a', 'b', 'c', 'd')") === "abcd"
    assert eval("concat('a', 'b', 'c', 'd', 'e')") === "abcde"
    assert eval("concat('a', 'b', 'c', 'd', 'e', 'f')") === "abcdef"
  end
end
