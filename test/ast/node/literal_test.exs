defmodule LiteralTest do
  import AST.Node.Literal
  use Query.EvaluationTestCase, async: true

  test "literals" do
    assert eval("null") == nil
    assert eval("false") == false
    assert eval("true") == true
    assert eval("123") == 123
    assert eval("4.5") == 4.5
    assert eval("1.") == 1.0
    assert eval("1. + 2") == 3.0
    assert eval("'abc'") == "abc"
  end

  test "to_source" do
    assert to_source(%AST.Node.Literal{value: "abc"}) == "'abc'"
    assert to_source(%AST.Node.Literal{value: "💩"}) == "'💩'"
    assert to_source(%AST.Node.Literal{value: "\u0008"}) == ~S['\b']
    assert to_source(%AST.Node.Literal{value: "\u000c"}) == ~S['\f']
    assert to_source(%AST.Node.Literal{value: "\u000a"}) == ~S['\n']
    assert to_source(%AST.Node.Literal{value: "\u000d"}) == ~S['\r']
    assert to_source(%AST.Node.Literal{value: "\u0009"}) == ~S['\t']
    assert to_source(%AST.Node.Literal{value: "𝄞"}) == ~S['𝄞']
  end

  # Floats print with an exponent when very large or small, which must parse back.
  test "to_source of a float parses back to the same value" do
    for value <- [1.0e20, -1.0e20, 1.0e-7, 1.5, 1.0e300] do
      assert eval(to_source(%AST.Node.Literal{value: value})) == value
    end
  end
end
