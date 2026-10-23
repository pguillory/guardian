defmodule Query.Function.Sha1Test do
  use Query.EvaluationTestCase, async: true

  test "sha1 function" do
    assert eval("sha1('abc')") === "a9993e364706816aba3e25717850c26c9cd0d89d"
  end
end
