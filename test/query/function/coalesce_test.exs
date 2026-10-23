defmodule Query.Function.CoalesceTest do
  use Query.EvaluationTestCase, async: true

  test "coalesce function" do
    assert eval("coalesce(1)") === 1
    assert eval("coalesce(null)") === nil

    assert eval("coalesce(1, 2)") === 1
    assert eval("coalesce(null, 2)") === 2
    assert eval("coalesce(null, null)") === nil

    assert eval("coalesce(1, 2, 3)") === 1
    assert eval("coalesce(null, 2, 3)") === 2
    assert eval("coalesce(null, null, 3)") === 3
    assert eval("coalesce(null, null, null)") === nil

    assert eval("coalesce(1, 2, 3, 4)") === 1
    assert eval("coalesce(null, 2, 3, 4)") === 2
    assert eval("coalesce(null, null, 3, 4)") === 3
    assert eval("coalesce(null, null, null, 4)") === 4
    assert eval("coalesce(null, null, null, null)") === nil
  end
end
