defmodule Guardian.Query.Function.LengthTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "length function" do
    assert eval("length('Abc')") === 3
  end
end
