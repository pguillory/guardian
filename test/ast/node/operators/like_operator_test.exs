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

  test "% followed by _ still requires a character" do
    assert eval("'' like '%_'") == false
    assert eval("'a' like '%_'") == true
    assert eval("'x' like '%_x'") == false
    assert eval("'ax' like '%_x'") == true
    assert eval("'' like '%%_'") == false
    assert eval("'ab' like '%_%_'") == true
    assert eval("'a' like '%_%_'") == false
  end

  test "a run of %_ against a long value is fast" do
    value = String.duplicate("a", 1_000)
    pattern = String.duplicate("%_", 20) <> "x"
    {micros, result} = :timer.tc(fn -> eval("'#{value}' like '#{pattern}'") end)
    assert result == false
    assert micros < 1_000_000

    short = String.duplicate("a", 30)

    {micros, result} =
      :timer.tc(fn -> eval("'#{short}' like '#{String.duplicate("%_", 31)}'") end)

    assert result == false
    assert micros < 1_000_000
  end

  test "redundant % wildcards" do
    assert eval("'quick brown fox' like '%%brown%%'") == true
    assert eval("'quick blue fox' like '%%brown%%'") == false
  end
end
