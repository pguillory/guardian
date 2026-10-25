defmodule Guardian.AST.Node.Operators.IlikeOperatorTest do
  use Guardian.Query.EvaluationTestCase, async: true

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

  describe "long values and LIKE equivalence" do
    @max Guardian.Query.Text.max_bytes()

    test "matches a long value exactly as LIKE matches its lowercase" do
      long = String.duplicate("A", @max) <> "Needle"
      assert eval("a ILIKE '%needle'", a: long) == true
      assert eval("a NOT ILIKE '%needle'", a: long) == false
      assert eval("a ILIKE b", a: long, b: "%NEEDLE") == true

      # lower() is cut to the cap, so it would lose the match.
      assert eval("lower(a) LIKE '%needle'", a: long) == false
    end

    test "agrees with LIKE on lowercased text, including invalid UTF-8" do
      for {value, pattern} <- [
            {"ÉCOLE", "%école"},
            {"Straße", "STRASSE"},
            {<<0xFF, ?A>>, "%a"},
            {"abc", <<?A, 0xFF>>},
            {"x", "_"},
          ] do
        expected =
          Guardian.AST.Node.Operators.LikeOperator.eval(
            String.downcase(value),
            String.downcase(pattern)
          )

        assert eval("a ILIKE b", a: value, b: pattern) == expected
        assert Guardian.AST.Node.Operators.IlikeOperator.eval(value, pattern) == expected
      end

      assert eval("a ILIKE b", a: 1, b: "1") == nil
    end
  end
end
