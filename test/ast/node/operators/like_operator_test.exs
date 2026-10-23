defmodule LikeOperatorTest do
  use Query.EvaluationTestCase, async: true

  test "like operator" do
    assert eval("'' like ''") == true
    assert eval("'a' like ''") == false

    assert eval("'' like '_'") == false
    assert eval("'a' like '_'") == true
    assert eval("'ab' like '_'") == false

    assert eval("'' like '__'") == false
    assert eval("'a' like '__'") == false
    assert eval("'ab' like '__'") == true
    assert eval("'abc' like '__'") == false

    assert eval("'abc' like '%a%'") == true
    assert eval("'abc' like '%b%'") == true
    assert eval("'abc' like '%c%'") == true
    assert eval("'abc' like '%d%'") == false

    assert eval("'quick brown fox' like '%brown%'") == true
    assert eval("'quick blue fox' like '%brown%'") == false

    assert eval("'quick BROWN fox' like '%brown%'") == false
    assert eval("'quick brown fox' like '%BROWN%'") == false
  end

  test "redundant % wildcards" do
    assert eval("'quick brown fox' like '%%brown%%'") == true
    assert eval("'quick blue fox' like '%%brown%%'") == false
  end
end
