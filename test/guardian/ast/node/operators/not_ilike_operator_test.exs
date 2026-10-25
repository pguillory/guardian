defmodule Guardian.AST.Node.Operators.NotIlikeOperatorTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "not ilike operator" do
    assert eval("'' not ilike ''") == false
    assert eval("'a' not ilike ''") == true

    assert eval("'' not ilike '_'") == true
    assert eval("'a' not ilike '_'") == false
    assert eval("'ab' not ilike '_'") == true

    assert eval("'' not ilike '__'") == true
    assert eval("'a' not ilike '__'") == true
    assert eval("'ab' not ilike '__'") == false
    assert eval("'abc' not ilike '__'") == true

    assert eval("'abc' not ilike '%a%'") == false
    assert eval("'abc' not ilike '%b%'") == false
    assert eval("'abc' not ilike '%c%'") == false
    assert eval("'abc' not ilike '%d%'") == true

    assert eval("'quick brown fox' not ilike '%brown%'") == false
    assert eval("'quick blue fox' not ilike '%brown%'") == true

    assert eval("'quick BROWN fox' not ilike '%brown%'") == false
    assert eval("'quick brown fox' not ilike '%BROWN%'") == false
  end
end
