defmodule Guardian.AST.Node.Operators.NotInOperatorTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "not in operator is the negation of in, with SQL's nulls" do
    assert eval("1 not in [1, 2]") == false
    assert eval("3 not in [1, 2]") == true
    assert eval("null not in [1, 2]") == nil

    assert eval("1 not in [1, null, 3]") == false
    assert eval("2 not in [1, null, 3]") == nil
    assert eval("null not in [1, null, 3]") == nil

    assert eval("1 not in []") == true
    assert eval("null not in []") == true
  end

  test "a right side that is not a list gives null" do
    assert eval("1 not in 1") == nil
    assert eval("'a' not in 'a'") == nil
    assert eval("1 not in ([1])") == false
  end

  test "over columns, the segment result matches row by row" do
    rows = [
      %{x: 1, l: [1, 2]},
      %{x: 3, l: [1, 2]},
      %{x: nil, l: [1]},
      %{x: 2, l: [nil]},
      %{x: 1, l: nil},
      %{x: "s", l: ["s"]},
    ]

    expected = [false, true, nil, nil, nil, false]
    assert eval_segment_and_rows("x NOT IN l", rows) == {expected, expected}

    assert eval_segment_and_rows("x NOT IN [1, 2]", rows) ==
             {[false, true, nil, false, false, true], [false, true, nil, false, false, true]}
  end
end
