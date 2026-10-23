defmodule IlikeOperatorTest do
  use Query.EvaluationTestCase, async: true

  test "ilike operator" do
    assert eval("'' ilike ''") == true
    assert eval("'a' ilike ''") == false

    assert eval("'' ilike '_'") == false
    assert eval("'a' ilike '_'") == true
    assert eval("'ab' ilike '_'") == false

    assert eval("'' ilike '__'") == false
    assert eval("'a' ilike '__'") == false
    assert eval("'ab' ilike '__'") == true
    assert eval("'abc' ilike '__'") == false

    assert eval("'abc' ilike '%a%'") == true
    assert eval("'abc' ilike '%b%'") == true
    assert eval("'abc' ilike '%c%'") == true
    assert eval("'abc' ilike '%d%'") == false

    assert eval("'quick brown fox' ilike '%brown%'") == true
    assert eval("'quick blue fox' ilike '%brown%'") == false

    assert eval("'quick BROWN fox' ilike '%brown%'") == true
    assert eval("'quick brown fox' ilike '%BROWN%'") == true
  end
end
