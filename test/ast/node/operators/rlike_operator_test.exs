defmodule RlikeOperatorTest do
  use Query.EvaluationTestCase, async: true

  test "rlike operator" do
    assert eval("'ab' rlike 'a'") == true
    assert eval("'ab' rlike 'b'") == true
    assert eval("'ab' rlike 'c'") == false
  end

  test "the pattern ends at a lower-precedence operator" do
    assert eval("'ab' rlike 'a' and 1 = 1") == true
    assert eval("'ab' rlike 'c' or 1 = 1") == true
    assert eval("'ab' rlike 'a' = true") == true
  end

  test "quantifiers, alternation, flags and anchors" do
    assert eval("'/u/123' rlike '[0-9]+'") == true
    assert eval("'ab' rlike 'a|ab'") == true
    assert eval("'ABC' rlike 'abc'") == false
    assert eval("'ABC' rlike '(?i)abc'") == true
    assert eval("'abc' rlike '^b'") == false
    assert eval("'abc' rlike '^a.c$'") == true
    assert eval("'a\nb' rlike '^b'") == false
    assert eval("'a\nb' rlike '(?m)^b'") == true
  end

  test "patterns that can match empty" do
    assert eval("'' rlike 'x*'") == true
    assert eval("'abc' rlike 'x*'") == true
    assert eval("null rlike 'x*'") == nil
  end

  test "UTF-8 strings match by codepoint" do
    assert eval("'é' rlike '^.$'") == true
    assert eval("'É' rlike '(?i)^é$'") == true
    assert eval("'a😀b' rlike 'a.b'") == true
    # Character classes stay ASCII by default.
    assert eval(~S"'é' rlike '^\\w$'") == false
    assert eval(~S"'é' rlike '(*UCP)^\\w$'") == true
    assert eval(~S"'٣' rlike '\\d'") == false
  end

  test "null, non-string and non-UTF-8 values give null" do
    assert eval("null rlike 'a'") == nil
    assert eval("123 rlike '1'") == nil
    assert eval("s rlike 'a'", s: <<97, 255>>) == nil
    assert eval("s rlike 'é'", s: <<97, 255>>) == nil
  end

  test "past the backtracking limit, RLIKE and NOT RLIKE are null" do
    evil = String.duplicate("a", 40) <> "b"
    assert eval("s rlike '(a+)+$'", s: evil) == nil
    assert eval("s not rlike '(a+)+$'", s: evil) == nil
    assert eval("s rlike '(a+)+$'", s: "aa") == true
  end
end
