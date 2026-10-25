defmodule Guardian.NotLikeOperatorTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "not like operator" do
    assert eval("'' not like ''") == false
    assert eval("'a' not like ''") == true

    assert eval("'' not like '_'") == true
    assert eval("'a' not like '_'") == false
    assert eval("'ab' not like '_'") == true

    assert eval("'' not like '__'") == true
    assert eval("'a' not like '__'") == true
    assert eval("'ab' not like '__'") == false
    assert eval("'abc' not like '__'") == true

    assert eval("'abc' not like '%a%'") == false
    assert eval("'abc' not like '%b%'") == false
    assert eval("'abc' not like '%c%'") == false
    assert eval("'abc' not like '%d%'") == true

    assert eval("'quick brown fox' not like '%brown%'") == false
    assert eval("'quick blue fox' not like '%brown%'") == true

    assert eval("'quick BROWN fox' not like '%brown%'") == true
    assert eval("'quick brown fox' not like '%BROWN%'") == true
  end

  test "redundant % wildcards" do
    assert eval("'quick brown fox' not like '%%brown%%'") == false
    assert eval("'quick blue fox' not like '%%brown%%'") == true
  end
end
