defmodule AST.RuleParserTest do
  use ExUnit.Case, async: true

  alias AST.Node.Identifier
  alias AST.Node.Statements.SetStatement
  alias AST.Node.Statements.UnsetStatement
  alias AST.Parser

  defp sources(source),
    do: source |> Parser.parse_rules() |> Enum.map(fn {s, line} -> {AST.unparse(s), line} end)

  test "parses SET and UNSET, with and without WHERE, and their lines" do
    source = """
    -- severity
    SET severity = 'high';
    SET severity2 = 'high' WHERE status >= 500;

    UNSET password;
    unset debug_payload where env = 'prod'
    """

    assert sources(source) == [
             {"SET severity = 'high'", 2},
             {"SET severity2 = 'high' WHERE status >= 500", 3},
             {"UNSET password", 5},
             {"UNSET debug_payload WHERE env = 'prod'", 6},
           ]

    assert [{%SetStatement{field: %Identifier{name: "severity"}, where_expr: nil}, 2} | _] =
             Parser.parse_rules(source)
  end

  test "round trips through to_source" do
    for source <- [
          "SET x = CASE WHEN a > 1 THEN 'a' ELSE 'b' END WHERE y IN [1, 2]",
          "SET email = lower(email)",
          "UNSET user.password WHERE NOT keep",
          "SET n = n + 1",
        ] do
      [{statement, 1}] = Parser.parse_rules(source)
      assert AST.unparse(statement) == source
      [{again, 1}] = Parser.parse_rules(AST.unparse(statement))
      assert again == statement
    end
  end

  test "statement words are contextual: usable as field names" do
    assert sources("SET set = last; UNSET last; SET unset = track WHERE lookup") == [
             {"SET set = last", 1},
             {"UNSET last", 1},
             {"SET unset = track WHERE lookup", 1},
           ]

    # And still plain identifiers in queries and as table names.
    assert [%AST.Node.Statements.SelectStatement{}] =
             AST.parse_statements("SELECT set, last FROM set")

    assert Engine.valid_table_name?("set") and Engine.valid_table_name?("last")
  end

  test "an expression stops before a trailing word it cannot continue with" do
    assert_raise AST.ParseError, ~r/Expected end of statement, got last/, fn ->
      Parser.parse_rules("SET x = a WHERE b > 1 last '1h'")
    end
  end

  test "empty files and empty statements" do
    assert Parser.parse_rules("") == []
    assert Parser.parse_rules("-- nothing\n;;") == []
    assert [{%UnsetStatement{}, 1}] = Parser.parse_rules("UNSET a;")
  end

  test "errors carry positions" do
    for {source, message} <- [
          {"SELECT 1", "line 1 column 1: Expected SET or UNSET statement, got SELECT"},
          {"SET a.b = 1", "line 1 column 5: SET takes a top-level field name, not a path"},
          {"UNSET a..b", "line 1 column 7: UNSET takes an object path without list boundaries"},
          {"SET x 1", "line 1 column 7: Expected punctuation: =, got 1"},
          {"\nSET x = nosuch(1)", "line 2 column 9: Invalid function nosuch"},
          {"TRACK c = count() BY ip LAST '1h'", "TRACK statements are not supported yet"},
          {"SET x = 1 SET y = 2", "Expected end of statement, got SET"},
        ] do
      error = assert_raise AST.ParseError, fn -> Parser.parse_rules(source) end
      assert Exception.message(error) =~ message
    end
  end
end
