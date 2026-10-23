defmodule NoOperatorTest do
  use Query.EvaluationTestCase, async: true

  test "not operator" do
    assert eval("not null") == nil
    assert eval("not false") == true
    assert eval("not true") == false
    assert eval("not 123") == nil
    assert eval("not 4.5") == nil
    assert eval("not 'a'") == nil
  end

  test "not applies to a whole comparison" do
    assert eval("not 1 = 2") == true
    assert eval("not 1 = 1") == false
    assert eval("not 1 in [2, 3]") == true
    assert eval("not 'ab' like 'a%'") == false
    assert eval("not 2 between 1 and 3") == false
    assert eval("not false and false") == false
    assert eval("not x = 1", x: 2) == true
    assert eval("not x = 1", x: 1) == false

    rows = [%{x: 1}, %{x: 2}, %{x: nil}, %{x: "a"}]

    assert {[false, true, nil, true], [false, true, nil, true]} =
             eval_segment_and_rows("not x = 1", rows)
  end
end
