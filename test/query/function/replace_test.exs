defmodule Query.Function.ReplaceTest do
  use Query.EvaluationTestCase, async: true

  test "replace function" do
    assert eval("replace('abcde', '[bd]', '_')") === "a_c_e"
    # assert eval("replace('abcde', '[', '_')") === nil

    assert eval("replace(null, '[bd]', '_')") === nil
    # assert eval("replace('abcde', null, '_')") === nil
    assert eval("replace('abcde', '[bd]', null)") === nil
  end
end
