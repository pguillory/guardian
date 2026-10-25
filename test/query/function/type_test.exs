defmodule Guardian.Query.Function.TypeTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "type function" do
    assert eval("type(null)") === "null"
    assert eval("type(false)") === "boolean"
    assert eval("type(true)") === "boolean"
    assert eval("type(123)") === "integer"
    assert eval("type(4.5)") === "float"
    assert eval("type('a')") === "string"

    assert eval("type([null])") === ["null"]
    assert eval("type([false])") === ["boolean"]
    assert eval("type([true])") === ["boolean"]
    assert eval("type([123])") === ["integer"]
    assert eval("type([4.5])") === ["float"]
    assert eval("type(['a'])") === ["string"]

    assert eval("type([null, null])") === ["null"]

    assert eval("type([null, false, true, 123, 4.5, 'a'])") === [
             "boolean",
             "float",
             "integer",
             "null",
             "string",
           ]

    assert eval("type(['a', 4.5, 123, true, false, null])") === [
             "boolean",
             "float",
             "integer",
             "null",
             "string",
           ]
  end
end
