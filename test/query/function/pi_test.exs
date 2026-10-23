defmodule Query.Function.PiTest do
  use Query.EvaluationTestCase, async: true

  test "pi function" do
    assert eval("pi()") === 3.141592653589793
  end
end
