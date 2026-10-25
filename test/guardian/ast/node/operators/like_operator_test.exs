defmodule Guardian.LikeOperatorTest do
  use Guardian.Query.EvaluationTestCase, async: true

  alias Guardian.AST.Node.Operators.LikeOperator

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

  test "no pattern backtracks: alternating literals and % stay fast" do
    value = String.duplicate("a", 16_384)
    pattern = String.duplicate("%a", 999) <> "%b"
    {micros, result} = :timer.tc(fn -> eval("'#{value}' like '#{pattern}'") end)
    assert result == false
    assert micros < 1_000_000

    {micros, result} =
      :timer.tc(fn -> eval("'#{String.duplicate("a", 80)}' like '%a%a%a%a%a%b'") end)

    assert result == false
    assert micros < 1_000_000
  end

  test "a pattern of more than 1,000 characters besides % matches nothing" do
    at_limit = String.duplicate("%a", 1_000)
    assert LikeOperator.eval(String.duplicate("a", 1_000), at_limit) == true
    assert LikeOperator.eval(String.duplicate("a", 1_001), at_limit <> "a") == nil
    assert LikeOperator.eval("x", String.duplicate("_", 1_001)) == nil
  end

  test "a long, varied pattern costs little, as a constant or per row" do
    # Distinct code points, each with its own state mask: bounded by the item cap.
    varied = 0x10000..0x1FFFF |> Enum.map(&<<&1::utf8>>) |> Enum.join()
    {micros, result} = :timer.tc(fn -> LikeOperator.eval("", varied) end)
    assert result == nil
    assert micros < 1_000_000

    pattern = 0x4E00..0x51E7 |> Enum.map(&<<&1::utf8>>) |> Enum.join()
    {micros, result} = :timer.tc(fn -> eval("'x' like '#{pattern}'") end)
    assert result == false
    assert micros < 1_000_000
  end

  test "_ is one character of UTF-8 text, one byte otherwise" do
    assert eval("'é' like '_'") == true
    assert eval("'日本' like '__'") == true
    assert eval("'日本' like '_'") == false
    assert LikeOperator.eval(<<0xFF, 0xFE>>, "__") == true
    assert LikeOperator.eval(<<0xFF, ?a>>, "%a") == true
    # An invalid pattern selects bytes too: "é" is the two bytes 0xC3 0xA9.
    assert LikeOperator.eval("é", <<?_, 0xA9>>) == true
  end

  test "agrees with an equivalent regular expression on random cases" do
    for _ <- 1..2_000 do
      value = random_string(Enum.random(0..8), ~w[a b])
      pattern = random_string(Enum.random(0..6), ~w[a b % _])

      regex =
        pattern
        |> String.graphemes()
        |> Enum.map_join(fn
          "%" -> ".*"
          "_" -> "."
          char -> Regex.escape(char)
        end)

      expected = Regex.match?(Regex.compile!("\\A" <> regex <> "\\z", "s"), value)
      assert LikeOperator.eval(value, pattern) == expected
    end
  end

  defp random_string(length, chars) do
    Enum.map_join(1..length//1, fn _ -> Enum.random(chars) end)
  end

  test "redundant % wildcards" do
    assert eval("'quick brown fox' like '%%brown%%'") == true
    assert eval("'quick blue fox' like '%%brown%%'") == false
  end
end
