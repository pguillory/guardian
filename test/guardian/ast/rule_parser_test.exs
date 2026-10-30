defmodule Guardian.AST.RuleParserTest do
  use ExUnit.Case, async: true

  alias Guardian.AST.Node.Identifier
  alias Guardian.AST.Node.Statements.LookupStatement
  alias Guardian.AST.Node.Statements.SetStatement
  alias Guardian.AST.Node.Statements.TrackStatement
  alias Guardian.AST.Node.Statements.UnsetStatement
  alias Guardian.AST.Parser

  defp sources(source) do
    source
    |> Parser.parse_rules()
    |> Enum.map(fn {s, line} -> {Guardian.AST.unparse(s), line} end)
  end

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
      assert Guardian.AST.unparse(statement) == source
      [{again, 1}] = Parser.parse_rules(Guardian.AST.unparse(statement))
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
    assert [%Guardian.AST.Node.Statements.SelectStatement{}] =
             Guardian.AST.parse_statements("SELECT set, last FROM set")

    assert Guardian.Engine.valid_table_name?("set") and Guardian.Engine.valid_table_name?("last")
  end

  test "literal false and null WHERE predicates remain in canonical rule source" do
    for predicate <- ["false", "null"],
        source <- [
          "SET x = 1 WHERE #{predicate}",
          "UNSET password WHERE #{predicate}",
          "TRACK c = count() WHERE #{predicate} LAST '1h'",
          "LOOKUP x = c WHERE #{predicate}",
        ] do
      [{statement, 1}] = Parser.parse_rules(source)
      assert Guardian.AST.unparse(statement) == source
      assert Parser.parse_rules(Guardian.AST.unparse(statement)) == [{statement, 1}]
    end
  end

  test "parses counter statements with all optional clauses and source lines" do
    source = """
    -- counters
    TRACK logins_last_hour = count() BY ip LAST '1h';
    TRACK spend_today = sum(amount) BY user_id WHERE status = 'ok' LAST '1d';

    LOOKUP prior_logins = logins_last_hour BY ip;
    LOOKUP user_spend = spend_today FROM transactions BY buyer_id WHERE amount > 100
    """

    assert sources(source) == [
             {"TRACK logins_last_hour = count() BY ip LAST '1h'", 2},
             {"TRACK spend_today = sum(amount) BY user_id WHERE status = 'ok' LAST '1d'", 3},
             {"LOOKUP prior_logins = logins_last_hour BY ip", 5},
             {"LOOKUP user_spend = spend_today FROM transactions BY buyer_id WHERE amount > 100",
              6},
           ]

    assert [{%TrackStatement{field: %Identifier{name: "logins_last_hour"}}, 2} | _] =
             Parser.parse_rules(source)

    assert [{%LookupStatement{counter: %Identifier{name: "c"}, from_table: nil, by_exprs: []}, 1}] =
             Parser.parse_rules("LOOKUP value = c")
  end

  test "counter syntax round trips with optional clauses, scalar expressions and all v1 aggregates" do
    for source <- [
          "TRACK c = count() LAST '1h'",
          "TRACK c = count(x) WHERE keep LAST '1h'",
          "TRACK c = count_distinct(lower(user.id)) BY ip, user.agent LAST '1d'",
          "TRACK c = sum(amount + 1) BY last WHERE last = 'x' LAST '1h'",
          "TRACK c = min(amount) LAST '1s'",
          "TRACK c = max(amount) LAST '1w'",
          "TRACK c = avg(amount) LAST '1m'",
          "TRACK c = count() BY last LAST '1h'",
          "TRACK c = count() BY last, ip LAST '1h'",
          "TRACK c = count() WHERE last LAST '1h'",
          "LOOKUP x = c",
          "LOOKUP x = c WHERE keep",
          "LOOKUP x = c BY lower(ip), CASE WHEN keep THEN id ELSE fallback END",
          "LOOKUP x = c BY ip WHERE keep",
          "LOOKUP x = c FROM t",
          "LOOKUP x = c FROM t WHERE keep",
          "LOOKUP x = c FROM t BY ip",
          "LOOKUP x = c FROM t BY ip WHERE keep",
          "LOOKUP x = c FROM t BY ip, last WHERE keep > 0",
          "TRACK track = count() BY lookup, last WHERE unset LAST '1h'",
          "LOOKUP lookup = track FROM last BY set WHERE unset",
        ] do
      [{statement, 1}] = Parser.parse_rules(source)
      assert Guardian.AST.unparse(statement) == source
      assert Parser.parse_rules(Guardian.AST.unparse(statement)) == [{statement, 1}]
    end
  end

  test "canonical counter source ignores comments, word case and spacing but preserves names" do
    [{statement, 2}] =
      Parser.parse_rules("-- same definition\ntrack c=COUNT(*) by ip,last where keep last '1h';")

    canonical = "TRACK c = count() BY ip, last WHERE keep LAST '1h'"
    assert Guardian.AST.unparse(statement) == canonical
    assert Parser.parse_rules(canonical) == [{statement, 1}]

    for changed <- [
          "TRACK renamed = count() BY ip, last WHERE keep LAST '1h'",
          "TRACK C = count() BY ip, last WHERE keep LAST '1h'",
          "TRACK c = count() BY IP, last WHERE keep LAST '1h'",
          "TRACK c = count(x) BY ip, last WHERE keep LAST '1h'",
          "TRACK c = count() BY last, ip WHERE keep LAST '1h'",
          "TRACK c = count() BY ip, last WHERE other LAST '1h'",
          "TRACK c = count() BY ip, last WHERE keep LAST '2h'",
        ] do
      [{different, 1}] = Parser.parse_rules(changed)
      refute Guardian.AST.unparse(different) == canonical
    end

    assert sources("lookup x=c from t by ip -- group\n where keep") == [
             {"LOOKUP x = c FROM t BY ip WHERE keep", 1},
           ]
  end

  test "counter nodes traverse and rewrite every child in source order" do
    for {source, pre_children, post_children} <- [
          {"TRACK c = sum(amount) BY ip, last WHERE keep > 0 LAST '1h'",
           ["c", "sum(amount)", "amount", "ip", "last", "keep > 0", "keep", "0", "'1h'"],
           ["c", "amount", "sum(amount)", "ip", "last", "keep", "0", "keep > 0", "'1h'"]},
          {"LOOKUP x = c FROM t BY ip, last WHERE keep > 0",
           ["x", "c", "t", "ip", "last", "keep > 0", "keep", "0"],
           ["x", "c", "t", "ip", "last", "keep", "0", "keep > 0"]},
          {"TRACK c = count() LAST '1h'", ["c", "count()", "'1h'"], ["c", "count()", "'1h'"]},
          {"LOOKUP x = c", ["x", "c"], ["x", "c"]},
        ] do
      [{statement, 1}] = Parser.parse_rules(source)

      {_, pre} =
        Guardian.AST.prewalk(statement, [], fn node, acc ->
          {node, acc ++ [Guardian.AST.unparse(node)]}
        end)

      {_, post} =
        Guardian.AST.postwalk(statement, [], fn node, acc ->
          {node, acc ++ [Guardian.AST.unparse(node)]}
        end)

      assert pre == [source | pre_children]
      assert post == post_children ++ [source]

      modified =
        Guardian.AST.prewalk(statement, fn
          %Identifier{name: name} -> %Identifier{name: "new_" <> name}
          %Guardian.AST.Node.Literal{value: "1h"} -> %Guardian.AST.Node.Literal{value: "2h"}
          node -> node
        end)

      rewritten = Guardian.AST.unparse(modified)
      refute rewritten == source
      assert Parser.parse_rules(rewritten) == [{modified, 1}]
    end
  end

  test "counter semantic restrictions are deferred to whole-set validation" do
    for source <- [
          "TRACK c = all(x) LAST 'not an interval'",
          "TRACK c = sum(count()) BY x AS y WHERE avg(a) > 1 LAST '0s'",
          "LOOKUP x = c FROM current_timestamp BY * WHERE count() > 1",
        ] do
      assert [{_, 1}] = Parser.parse_rules(source)
    end
  end

  test "counter syntax stays out of query parsing and statement words stay identifiers" do
    assert [%Guardian.AST.Node.Statements.SelectStatement{}] =
             Guardian.AST.parse_statements("SELECT track, lookup, last FROM last")

    for name <- ~w[track lookup last], do: assert(Guardian.Engine.valid_table_name?(name))

    for source <- ["TRACK c = count() LAST '1h'", "LOOKUP x = c"] do
      assert_raise Guardian.AST.ParseError, fn -> Guardian.AST.parse_statements(source) end
    end
  end

  test "rejects malformed counter syntax at the offending token" do
    for {source, message} <- [
          {"TRACK c = count()", "line 1 column 18: Expected LAST clause, got end of input"},
          {"TRACK c = count() LAST 1", "line 1 column 24: Expected interval string, got 1"},
          {"TRACK c = count() BY WHERE keep LAST '1h'", "Expected expression, got WHERE"},
          {"TRACK c = count() BY ip, WHERE keep LAST '1h'", "Expected expression, got WHERE"},
          {"TRACK c = count() WHERE keep BY ip LAST '1h'", "Expected LAST clause, got BY"},
          {"TRACK c = count() BY ip BY user LAST '1h'", "Expected LAST clause, got BY"},
          {"TRACK c = count() LAST '1h' LAST '2h'", "Expected end of statement, got LAST"},
          {"TRACK c = count() LAST '1' || 'h'", "Expected end of statement, got ||"},
          {"TRACK c = lower(x) LAST '1h'", "Expected aggregate function call, got lower"},
          {"TRACK c = (count()) LAST '1h'", "Expected aggregate function call, got ("},
          {"TRACK c = count() + 1 LAST '1h'", "Expected LAST clause, got +"},
          {"TRACK c = count() AS x LAST '1h'", "Expected LAST clause, got AS"},
          {"TRACK c = sum() LAST '1h'", "Wrong number of parameters for aggregate function sum"},
          {"TRACK c = count(a, b) LAST '1h'",
           "Wrong number of parameters for aggregate function count"},
          {"TRACK c = nosuch() LAST '1h'", "Invalid function nosuch"},
          {"TRACK a.b = count() LAST '1h'", "TRACK takes a top-level field name, not a path"},
          {"LOOKUP a.b = c", "LOOKUP takes a top-level field name, not a path"},
          {"LOOKUP x = a.b", "Counter name must be an identifier without dots"},
          {"LOOKUP x = c FROM a.b", "Table name must be an identifier without dots"},
          {"LOOKUP x = c FROM", "Expected table name, got end of input"},
          {"LOOKUP x =", "Expected counter name, got end of input"},
          {"LOOKUP x = count()", "Expected end of statement, got ("},
          {"LOOKUP x = c LAST '1h'", "Expected end of statement, got LAST"},
          {"LOOKUP x = c BY ip FROM t", "Expected end of statement, got FROM"},
          {"LOOKUP x = c FROM t FROM u", "Expected end of statement, got FROM"},
        ] do
      error = assert_raise Guardian.AST.ParseError, fn -> Parser.parse_rules(source) end
      assert Exception.message(error) =~ message
    end
  end

  test "an expression stops before a trailing word it cannot continue with" do
    assert_raise Guardian.AST.ParseError, ~r/Expected end of statement, got last/, fn ->
      Parser.parse_rules("SET x = a WHERE b > 1 last '1h'")
    end
  end

  test "empty files and empty statements" do
    assert Parser.parse_rules("") == []
    assert Parser.parse_rules("-- nothing\n;;") == []
    assert [{%UnsetStatement{}, 1}] = Parser.parse_rules("UNSET a;")
  end

  test "statement words match in any case, field names keep theirs" do
    assert [{%SetStatement{field: %Identifier{name: "isBlocked"}}, 1}] =
             Parser.parse_rules("sEt isBlocked = 1")

    assert [{%UnsetStatement{field: %Identifier{name: "User.Name"}}, 1}] =
             Parser.parse_rules("Unset User.Name")

    assert [{%TrackStatement{field: %Identifier{name: "Hits"}}, 1}] =
             Parser.parse_rules("Track Hits = Count() lAsT '1h'")

    assert [{%LookupStatement{counter: %Identifier{name: "Hits"}}, 1}] =
             Parser.parse_rules("LOOKUP prior = Hits")
  end

  test "UNSET takes any addressable column, including a list path" do
    assert [{%UnsetStatement{field: %Identifier{name: "users..email"}} = statement, 1}] =
             Parser.parse_rules("UNSET users..email")

    assert Guardian.AST.unparse(statement) == "UNSET users..email"
  end

  test "errors carry positions" do
    for {source, message} <- [
          {"SELECT 1", "line 1 column 1: Expected rule statement, got SELECT"},
          {"SET a.b = 1", "line 1 column 5: SET takes a top-level field name, not a path"},
          {"SET x 1", "line 1 column 7: Expected punctuation: =, got 1"},
          {"\nSET x = nosuch(1)", "line 2 column 9: Invalid function nosuch"},
          {"SET x = 1 SET y = 2", "Expected end of statement, got SET"},
        ] do
      error = assert_raise Guardian.AST.ParseError, fn -> Parser.parse_rules(source) end
      assert Exception.message(error) =~ message
    end
  end
end
