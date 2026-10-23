defmodule Query.Function.NormalizeTest do
  use Query.EvaluationTestCase, async: true

  test "normalize function" do
    assert eval("normalize('ﬁ')") === "ﬁ"
    assert eval("normalize('ﬁ', 'NFKD')") === "fi"
  end
end
