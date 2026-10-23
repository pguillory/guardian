defmodule LessThanOrEqualOperatorTest do
  use Query.EvaluationTestCase, async: true

  test "less than or equal operator" do
    assert eval("1 <= 2") == true
    assert eval("1 <= 1") == true
    assert eval("2 <= 1") == false

    assert eval("1.0 <= 2.0") == true
    assert eval("1.0 <= 1.0") == true
    assert eval("2.0 <= 1.0") == false

    assert eval("1.0 <= 2") == true
    assert eval("1.0 <= 1") == true
    assert eval("2.0 <= 1") == false

    assert eval("1 <= 2.0") == true
    assert eval("1 <= 1.0") == true
    assert eval("2 <= 1.0") == false

    assert eval("nil <= 2") == nil
    assert eval("nil <= nil") == nil
    assert eval("2 <= nil") == nil

    assert eval("'b' <= 'a'") == false
    assert eval("'b' <= 'b'") == true
    assert eval("'b' <= 'c'") == true
  end

  test "over a segment, a number literal on either side matches row-by-row results" do
    rows = for x <- [10, 1, 2.5, nil, "s", true, [3]], do: %{x: x}

    # Every number is on the true side here: only the numbers are true.
    assert eval_segment_and_rows("1 <= x", rows) ==
             {[true, true, true, nil, nil, nil, nil], [true, true, true, nil, nil, nil, nil]}

    for n <- [0, 1, 2, 2.2, 5, 10, 20] do
      for source <- ["x <= #{n}", "#{n} <= x"] do
        {segment, per_row} = eval_segment_and_rows(source, rows)
        assert segment == per_row, source
      end
    end

    no_numbers = for x <- [nil, "s", true, [3]], do: %{x: x}
    {segment, per_row} = eval_segment_and_rows("x <= 5", no_numbers)
    assert segment == per_row
    {segment, per_row} = eval_segment_and_rows("5 <= x", no_numbers)
    assert segment == per_row
  end
end
