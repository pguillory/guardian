defmodule Guardian.AST.Node.CaseTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "case expression" do
    assert eval("case when true then 1 end") == 1
    assert eval("case when false then 1 when true then 2 end") == 2
  end

  test "unparse round-trips" do
    for source <- [
          "CASE WHEN a THEN 1 END",
          "CASE WHEN a THEN 1 ELSE 2 END",
          "CASE WHEN a THEN 1 WHEN b THEN 2 ELSE 3 END",
          "CASE x WHEN 1 THEN 'one' END",
          "CASE x WHEN 1 THEN 'one' ELSE 'other' END",
        ] do
      assert Guardian.AST.unparse(Guardian.AST.Parser.parse_expression(source)) == source
    end
  end
end
