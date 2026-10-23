defmodule Query.Function.Md5Test do
  use Query.EvaluationTestCase, async: true

  test "md5 function" do
    assert eval("md5('abc')") === "900150983cd24fb0d6963f7d28e17f72"
  end
end
