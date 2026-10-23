defmodule Query.Function.ReplaceTest do
  use Query.EvaluationTestCase, async: true

  defp query_error(source, row \\ %{}) do
    assert_raise Query.Error, fn -> eval(source, row) end
  end

  test "replace function" do
    assert eval("replace('abcde', '[bd]', '_')") === "a_c_e"
    assert eval("replace(null, '[bd]', '_')") === nil
    assert eval("replace('abcde', '[bd]', null)") === nil
    assert eval("replace(123, '[0-9]', '_')") === nil
    assert eval("replace('abc', 'x', '_')") === "abc"
    assert eval("replace('', 'x', '_')") === ""
  end

  test "quantified patterns replace the whole match" do
    assert eval("replace('/u/123', '[0-9]+', ':id')") === "/u/:id"

    assert eval("replace(path, '[0-9]+', ':id')", path: "/users/42/posts/7") ===
             "/users/:id/posts/:id"

    assert eval("replace('a12b345', '[0-9]+', 'X')") === "aXbX"
    assert eval(~S"replace('1 22 333 4444', '\\d{2,3}', 'X')") === "1 X X X4"
    assert eval("replace('aaa', 'a+?', 'X')") === "XXX"
    assert eval("replace('xaaay', 'a+', '')") === "xy"
  end

  test "alternation and overlap are leftmost-first, non-overlapping" do
    assert eval("replace('ab', 'a|ab', 'X')") === "Xb"
    assert eval("replace('ab', 'ab|a', 'X')") === "X"
    assert eval("replace('aaa', 'aa', 'X')") === "Xa"
    assert eval("replace('aaaa', 'aa', 'X')") === "XX"
  end

  test "adjacent matches" do
    assert eval("replace('123', '[0-9]', 'X')") === "XXX"
    assert eval("replace('abab', 'ab', 'X')") === "XX"
    assert eval("replace('12ab34', '[0-9]+|[a-z]+', 'X')") === "XXX"
  end

  test "empty matches follow PCRE" do
    assert eval("replace('abc', 'x*', '-')") === "-a-b-c-"
    assert eval("replace('baaac', 'a*', '-')") === "-b--c-"
    assert eval("replace('a', '(?:|a)', 'XX')") === "XXXXXX"
    assert eval("replace('abc', '^', '>')") === ">abc"
    assert eval("replace('abc', '$', '<')") === "abc<"
    assert eval(~S"replace('ab cd', '\\b', '|')") === "|ab| |cd|"
    assert eval("replace('', 'x*', '-')") === "-"
  end

  test "the replacement is literal" do
    assert eval("replace('abc', 'b', '&')") === "a&c"
    assert eval(~S"replace('abc', '(b)', '\\1')") === ~S"a\1c"
    assert eval("replace('abc', '(b)', '$1')") === "a$1c"
    assert eval(~S"replace('abc', 'b', '\\')") === ~S"a\c"
  end

  test "UTF-8 strings match by codepoint" do
    assert eval("replace('héllo', '.', 'x')") === "xxxxx"
    assert eval("replace('hééllo', 'é+', 'e')") === "hello"
    assert eval("replace('a😀b😀', '😀', ':)')") === "a:)b:)"
    assert eval("replace('a😀b', '^a.b$', 'ok')") === "ok"
    assert eval("replace('É', '(?i)é', 'e')") === "e"
    assert eval("replace('abc', 'b', 'ß→')") === "aß→c"
  end

  test "a value that is not valid UTF-8 gives null" do
    for pattern <- [".", "a", "é", ~S"\\x{100}", "(*UTF).", "^$"] do
      assert eval("replace(s, '#{pattern}', 'x')", s: <<97, 255>>) === nil
    end

    assert eval("replace(s, 'a', 'x')", s: "abc") === "xbc"
  end

  test "a match that splits a character fails the query" do
    assert query_error(~S"replace('é', '^\\C', 'X')").message =~ "part of a character"
    assert query_error(~S"replace('aé', '\\C', 'X')").message =~ "part of a character"
  end

  test "a pattern with too many capturing groups is a parse error" do
    groups = String.duplicate("(a)", Query.Regex.max_groups())
    assert eval("replace('a', '#{groups}', 'x')") === "a"

    error = assert_raise AST.ParseError, fn -> eval("replace('a', '#{groups}(a)', 'x')") end
    assert error.reason =~ "more than 32 capturing groups"
  end

  test "backtracking too deep fails the query" do
    groups = String.duplicate("()", Query.Regex.max_groups())
    s = String.duplicate("a", 200_000) <> "x"
    error = query_error("replace(s, '(*NO_START_OPT)^(?:#{groups}a)*$', 'x')", s: s)
    assert error.message =~ "backtracking limit"
  end

  test "catastrophic backtracking fails the query" do
    error = query_error("replace(s, '(a+)+$', 'x')", s: String.duplicate("a", 40) <> "b")
    assert error.message =~ "regular expression too complex"
    assert error.message =~ "backtracking limit"
  end
end
