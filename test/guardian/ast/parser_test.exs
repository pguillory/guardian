defmodule Guardian.AST.ParserTest do
  alias Guardian.AST.ParseError
  use ExUnit.Case, async: true

  alias Guardian.AST.Node.Operators.AddOperator
  alias Guardian.AST.Node.Operators.AndOperator
  alias Guardian.AST.Node.Operators.BetweenOperator
  alias Guardian.AST.Node.Operators.EqualOperator
  alias Guardian.AST.Node.Operators.InOperator
  alias Guardian.AST.Node.Operators.IsOperator
  alias Guardian.AST.Node.Operators.ListLiteral
  alias Guardian.AST.Node.Operators.MultiplyOperator
  alias Guardian.AST.Node.Operators.NotInOperator
  alias Guardian.AST.Node.Operators.NotOperator
  alias Guardian.AST.Node.Operators.RlikeOperator

  alias Guardian.AST.Node.Statements.DescStatement
  alias Guardian.AST.Node.Statements.LetStatement
  alias Guardian.AST.Node.Statements.NullStatement
  alias Guardian.AST.Node.Statements.SelectStatement
  alias Guardian.AST.Node.Statements.ShowTablesStatement

  defmacro assert_parse_error(source, expected_error_indicator, expected_reason) do
    quote do
      assert %ParseError{reason: unquote(expected_reason)} = parse_failure(unquote(source))
      error = parse_failure(unquote(source))
      assert error_indicator(error.col) == unquote(expected_error_indicator)
    end
  end

  defp parse(source) do
    {:ok, parsed} = Guardian.AST.Parser.parse(source)
    parsed
  end

  defp parse_failure(source) do
    {:error, error} = Guardian.AST.Parser.parse(source)
    error
  end

  defp statements_failure(source) do
    {:error, error} = Guardian.AST.parse_statements(source)
    error
  end

  def error_indicator(col) do
    String.duplicate(" ", col) <> "^"
  end

  test "parse identifier" do
    assert parse("foo") == %Guardian.AST.Node.Identifier{name: "foo"}
  end

  test "parse dotted field path" do
    assert parse("user.name") == %Guardian.AST.Node.Identifier{name: "user.name"}
    assert parse("users..name") == %Guardian.AST.Node.Identifier{name: "users..name"}

    source = "SELECT user.name, sum(user.age) FROM t WHERE users..name = 'Bob' GROUP BY user.name"
    [statement] = parse(source)
    assert Guardian.AST.unparse(statement) == source

    assert_parse_error("select user. from t", "           ^", "Unexpected character")
  end

  test "parse literal" do
    assert parse("null") == %Guardian.AST.Node.Literal{value: nil}
    assert parse("false") == %Guardian.AST.Node.Literal{value: false}
    assert parse("true") == %Guardian.AST.Node.Literal{value: true}
    assert parse("123") == %Guardian.AST.Node.Literal{value: 123}
    assert parse("4.5") == %Guardian.AST.Node.Literal{value: 4.5}
    assert parse("'abc'") == %Guardian.AST.Node.Literal{value: "abc"}
    assert parse(~S['\u0024']) == %Guardian.AST.Node.Literal{value: "$"}
    assert parse(~S['\uD83D\uDCA9']) == %Guardian.AST.Node.Literal{value: "💩"}

    assert_parse_error(
      "select 'abc",
      "       ^",
      "Unterminated string literal"
    )

    assert_parse_error(
      "select 'foo \\uD801 bar' from t",
      "            ^",
      "Invalid UTF-16 codepoint"
    )

    assert_parse_error(
      "select 'foo \\x bar' from t",
      "            ^",
      "Bad escaped character"
    )

    assert_parse_error(
      "select 1.2.3",
      "          ^",
      "Unexpected character"
    )
  end

  test "list literal" do
    assert parse("[]") == %ListLiteral{exprs: []}
    assert parse("[1]") == %ListLiteral{exprs: [%Guardian.AST.Node.Literal{value: 1}]}

    assert parse("[1, 2]") == %ListLiteral{
             exprs: [%Guardian.AST.Node.Literal{value: 1}, %Guardian.AST.Node.Literal{value: 2}],
           }
  end

  test "invalid regex" do
    assert_parse_error(
      "'abcde' rlike '['",
      "              ^",
      "Invalid regular expression"
    )

    assert_parse_error(
      "replace('abcde', '[', '_')",
      "                 ^",
      "Invalid regular expression"
    )
  end

  test "patterns that can match empty are valid" do
    assert %RlikeOperator{} = parse("msg rlike 'x*'")
  end

  test "jq() is gone, with a message saying so" do
    assert_parse_error(
      "jq('.a', payload)",
      "^",
      "jq() was removed from Guardian. For ingested JSON objects, nested fields are " <>
        "already columns: query them by dotted name, for example payload.user.id"
    )

    assert parse("jq") == %Guardian.AST.Node.Identifier{name: "jq"}
  end

  test "an RLIKE pattern ends at AND" do
    assert parse("msg rlike 'a' and x = 1") == %AndOperator{
             left: %RlikeOperator{
               left: %Guardian.AST.Node.Identifier{name: "msg"},
               right: %Guardian.AST.Node.Literal{value: "a"},
             },
             right: %EqualOperator{
               left: %Guardian.AST.Node.Identifier{name: "x"},
               right: %Guardian.AST.Node.Literal{value: 1},
             },
           }

    source = "msg NOT RLIKE 'a' AND x = 1"
    assert Guardian.AST.unparse(parse(source)) == source
  end

  test "a string literal may end in an escaped backslash" do
    assert parse(~S['a\\' = 'b']) == %EqualOperator{
             left: %Guardian.AST.Node.Literal{value: "a\\"},
             right: %Guardian.AST.Node.Literal{value: "b"},
           }
  end

  test "bad string escapes are parse errors at the escape" do
    assert_parse_error(~S['ab\uzzzz'], "   ^", ~S[Invalid \u escape])
    assert_parse_error(~S[x = 'a\u0001\uD801'], "            ^", "Invalid UTF-16 codepoint")
  end

  test "interval" do
    assert parse("interval 1 hour") == %Guardian.AST.Node.FunctionCall{
             name: "interval",
             args: [%Guardian.AST.Node.Literal{value: "1h"}],
           }

    assert parse("interval 9223372036854775807 week") == %Guardian.AST.Node.FunctionCall{
             name: "interval",
             args: [%Guardian.AST.Node.Literal{value: "9223372036854775807w"}],
           }

    assert_parse_error("interval 9223372036854775808 week", "         ^", "Number out of range")
  end

  test "integer literals outside int64 are parse errors in every position" do
    assert_parse_error(
      "select 1 limit 9223372036854775808",
      "               ^",
      "Number out of range"
    )

    assert_parse_error("select 99999999999999999999", "       ^", "Number out of range")
    assert_parse_error("select -9223372036854775808", "        ^", "Number out of range")
  end

  test "parse parenthesized expression" do
    assert parse("(123)") == %Guardian.AST.Node.Parentheses{
             expr: %Guardian.AST.Node.Literal{value: 123},
           }

    assert_parse_error(
      "select (123 from",
      "            ^",
      "Expected punctuation: ), got from"
    )
  end

  test "parse binary expression" do
    assert parse("a is b") == %IsOperator{
             left: %Guardian.AST.Node.Identifier{name: "a"},
             right: %Guardian.AST.Node.Identifier{name: "b"},
           }

    assert parse("a + b") == %AddOperator{
             left: %Guardian.AST.Node.Identifier{name: "a"},
             right: %Guardian.AST.Node.Identifier{name: "b"},
           }

    assert parse("a * b") == %MultiplyOperator{
             left: %Guardian.AST.Node.Identifier{name: "a"},
             right: %Guardian.AST.Node.Identifier{name: "b"},
           }

    assert parse("a + b + c") == %AddOperator{
             left: %AddOperator{
               left: %Guardian.AST.Node.Identifier{name: "a"},
               right: %Guardian.AST.Node.Identifier{name: "b"},
             },
             right: %Guardian.AST.Node.Identifier{name: "c"},
           }

    assert parse("a * b + c") == %AddOperator{
             left: %MultiplyOperator{
               left: %Guardian.AST.Node.Identifier{name: "a"},
               right: %Guardian.AST.Node.Identifier{name: "b"},
             },
             right: %Guardian.AST.Node.Identifier{name: "c"},
           }

    assert parse("a + b * c") == %AddOperator{
             left: %Guardian.AST.Node.Identifier{name: "a"},
             right: %MultiplyOperator{
               left: %Guardian.AST.Node.Identifier{name: "b"},
               right: %Guardian.AST.Node.Identifier{name: "c"},
             },
           }

    assert parse("a * b * c") == %MultiplyOperator{
             left: %MultiplyOperator{
               left: %Guardian.AST.Node.Identifier{name: "a"},
               right: %Guardian.AST.Node.Identifier{name: "b"},
             },
             right: %Guardian.AST.Node.Identifier{name: "c"},
           }

    assert_parse_error(
      "select a + )",
      "           ^",
      "Expected expression, got )"
    )
  end

  test "parse between" do
    assert parse("a between b and c") == %BetweenOperator{
             left: %Guardian.AST.Node.Identifier{name: "a"},
             min_expr: %Guardian.AST.Node.Identifier{name: "b"},
             max_expr: %Guardian.AST.Node.Identifier{name: "c"},
           }

    assert parse("d and a between b and c") ==
             %AndOperator{
               left: %Guardian.AST.Node.Identifier{name: "d"},
               right: %BetweenOperator{
                 left: %Guardian.AST.Node.Identifier{name: "a"},
                 min_expr: %Guardian.AST.Node.Identifier{name: "b"},
                 max_expr: %Guardian.AST.Node.Identifier{name: "c"},
               },
             }

    assert parse("a between b and c and e") ==
             %AndOperator{
               left: %BetweenOperator{
                 left: %Guardian.AST.Node.Identifier{name: "a"},
                 min_expr: %Guardian.AST.Node.Identifier{name: "b"},
                 max_expr: %Guardian.AST.Node.Identifier{name: "c"},
               },
               right: %Guardian.AST.Node.Identifier{name: "e"},
             }

    assert parse("d and a between b and c and e") ==
             %AndOperator{
               left: %AndOperator{
                 left: %Guardian.AST.Node.Identifier{name: "d"},
                 right: %BetweenOperator{
                   left: %Guardian.AST.Node.Identifier{name: "a"},
                   min_expr: %Guardian.AST.Node.Identifier{name: "b"},
                   max_expr: %Guardian.AST.Node.Identifier{name: "c"},
                 },
               },
               right: %Guardian.AST.Node.Identifier{name: "e"},
             }
  end

  test "parse function" do
    assert parse("now()") == %Guardian.AST.Node.FunctionCall{name: "now", args: []}

    assert_parse_error(
      "select now(1)",
      "       ^",
      "Wrong number of parameters for function now"
    )

    assert_parse_error(
      "select floor()",
      "       ^",
      "Wrong number of parameters for function floor"
    )

    assert parse("floor(1)") == %Guardian.AST.Node.FunctionCall{
             name: "floor",
             args: [%Guardian.AST.Node.Literal{value: 1}],
           }

    assert_parse_error(
      "select avg()",
      "       ^",
      "Wrong number of parameters for aggregate function avg"
    )

    assert parse("avg(1)") == %Guardian.AST.Node.AggregateFunctionCall{
             name: "avg",
             args: [%Guardian.AST.Node.Literal{value: 1}],
           }

    assert_parse_error(
      "select avg(1, 2)",
      "       ^",
      "Wrong number of parameters for aggregate function avg"
    )

    assert_parse_error(
      "select foo()",
      "       ^",
      "Invalid function foo"
    )

    # assert_parse_error(
    #   "select foo(1)",
    #   "       ^",
    #   "Invalid function foo"
    # )
  end

  test "parse select" do
    assert_parse_error(
      "select ",
      "       ^",
      "Expected expression, got end of input"
    )

    assert parse("select foo") == [
             %SelectStatement{select_exprs: [%Guardian.AST.Node.Identifier{name: "foo"}]},
           ]

    assert parse("select foo, bar") == [
             %SelectStatement{
               select_exprs: [
                 %Guardian.AST.Node.Identifier{name: "foo"},
                 %Guardian.AST.Node.Identifier{name: "bar"},
               ],
             },
           ]

    assert parse("select 1 where 2") == [
             %SelectStatement{
               select_exprs: [%Guardian.AST.Node.Literal{value: 1}],
               where_expr: %Guardian.AST.Node.Literal{value: 2},
             },
           ]

    assert_parse_error(
      "select a limit b",
      "               ^",
      "Expected integer literal, got b"
    )
  end

  test "LIMIT may be at most 10,000" do
    assert {:ok, [%SelectStatement{limit_expr: %Guardian.AST.Node.Literal{value: 10_000}}]} =
             Guardian.AST.parse("select a limit 10000")

    assert_parse_error(
      "select a limit 10001",
      "         ^",
      "LIMIT 10001 exceeds the maximum of 10000"
    )
  end

  test "expected errors name the token found as written" do
    assert_parse_error(
      "select a from t UNION select b from t",
      "                ^",
      "Expected end of statement, got UNION"
    )

    assert_parse_error(
      "select a from t\n-- note\nwhere",
      "     ^",
      "Expected expression, got end of input"
    )

    long_string = "'" <> String.duplicate("x", 60) <> "'"

    assert %ParseError{reason: reason} =
             statements_failure("select a limit #{long_string}")

    assert reason == "Expected integer literal, got '" <> String.duplicate("x", 39) <> "..."
  end

  test "reject removed rule syntax" do
    assert %ParseError{reason: "Expected statements, got update"} =
             statements_failure("update events set approved = true")
  end

  test "parse let statement" do
    assert parse("let x = 1 + 2") == [
             %LetStatement{
               key_expr: %Guardian.AST.Node.Identifier{name: "x"},
               value_expr: %AddOperator{
                 left: %Guardian.AST.Node.Literal{value: 1},
                 right: %Guardian.AST.Node.Literal{value: 2},
               },
             },
           ]
  end

  test "INSERT is not a statement" do
    for source <- [
          "insert into a (b, c) values (1, 2)",
          "INSERT INTO a (b) VALUES (1)",
          "insert into a select b, c from d",
          "INSERT INTO a SELECT * FROM d",
        ] do
      assert %ParseError{} = parse_failure(source)
      assert %ParseError{} = statements_failure(source)
    end
  end

  test "DELETE is not a statement" do
    assert %ParseError{} = parse_failure("delete from a")
    assert %ParseError{} = statements_failure("DELETE FROM a")
  end

  test "parse show tables statement" do
    assert parse("show tables") == [
             %ShowTablesStatement{},
           ]
  end

  test "parse desc statement" do
    assert parse("desc foo") == [
             %DescStatement{expr: %Guardian.AST.Node.Identifier{name: "foo"}},
           ]
  end

  test "parse multiple statements" do
    assert parse("") == []

    assert parse("select 1") == [
             %SelectStatement{select_exprs: [%Guardian.AST.Node.Literal{value: 1}]},
           ]

    assert parse("select 1;") == [
             %SelectStatement{select_exprs: [%Guardian.AST.Node.Literal{value: 1}]},
             %NullStatement{},
           ]

    assert parse("select 1;;") == [
             %SelectStatement{select_exprs: [%Guardian.AST.Node.Literal{value: 1}]},
             %NullStatement{},
             %NullStatement{},
           ]

    assert parse(";select 1") == [
             %NullStatement{},
             %SelectStatement{select_exprs: [%Guardian.AST.Node.Literal{value: 1}]},
           ]

    assert parse(";;select 1") == [
             %NullStatement{},
             %NullStatement{},
             %SelectStatement{select_exprs: [%Guardian.AST.Node.Literal{value: 1}]},
           ]

    assert parse("select 1; select 2") == [
             %SelectStatement{select_exprs: [%Guardian.AST.Node.Literal{value: 1}]},
             %SelectStatement{select_exprs: [%Guardian.AST.Node.Literal{value: 2}]},
           ]

    assert parse("select 1; select 2;") == [
             %SelectStatement{select_exprs: [%Guardian.AST.Node.Literal{value: 1}]},
             %SelectStatement{select_exprs: [%Guardian.AST.Node.Literal{value: 2}]},
             %NullStatement{},
           ]
  end

  test "associativity" do
    assert associativity("1 + 2 + 3") == "((1 + 2) + 3)"
    assert associativity("1 + 2 - 3") == "((1 + 2) - 3)"
    assert associativity("1 + 2 * 3") == "(1 + (2 * 3))"
    assert associativity("1 + 2 / 3") == "(1 + (2 / 3))"
    assert associativity("1 + 2 AND 3") == "((1 + 2) AND 3)"
    assert associativity("1 + 2 OR 3") == "((1 + 2) OR 3)"

    assert associativity("1 - 2 + 3") == "((1 - 2) + 3)"
    assert associativity("1 - 2 - 3") == "((1 - 2) - 3)"
    assert associativity("1 - 2 * 3") == "(1 - (2 * 3))"
    assert associativity("1 - 2 / 3") == "(1 - (2 / 3))"
    assert associativity("1 - 2 AND 3") == "((1 - 2) AND 3)"
    assert associativity("1 - 2 OR 3") == "((1 - 2) OR 3)"

    assert associativity("1 * 2 + 3") == "((1 * 2) + 3)"
    assert associativity("1 * 2 - 3") == "((1 * 2) - 3)"
    assert associativity("1 * 2 * 3") == "((1 * 2) * 3)"
    assert associativity("1 * 2 / 3") == "((1 * 2) / 3)"
    assert associativity("1 * 2 AND 3") == "((1 * 2) AND 3)"
    assert associativity("1 * 2 OR 3") == "((1 * 2) OR 3)"

    assert associativity("1 / 2 + 3") == "((1 / 2) + 3)"
    assert associativity("1 / 2 - 3") == "((1 / 2) - 3)"
    assert associativity("1 / 2 * 3") == "((1 / 2) * 3)"
    assert associativity("1 / 2 / 3") == "((1 / 2) / 3)"
    assert associativity("1 / 2 AND 3") == "((1 / 2) AND 3)"
    assert associativity("1 / 2 OR 3") == "((1 / 2) OR 3)"

    assert associativity("1 AND 2 + 3") == "(1 AND (2 + 3))"
    assert associativity("1 AND 2 - 3") == "(1 AND (2 - 3))"
    assert associativity("1 AND 2 * 3") == "(1 AND (2 * 3))"
    assert associativity("1 AND 2 / 3") == "(1 AND (2 / 3))"
    assert associativity("1 AND 2 AND 3") == "((1 AND 2) AND 3)"
    assert associativity("1 AND 2 OR 3") == "((1 AND 2) OR 3)"

    assert associativity("1 OR 2 + 3") == "(1 OR (2 + 3))"
    assert associativity("1 OR 2 - 3") == "(1 OR (2 - 3))"
    assert associativity("1 OR 2 * 3") == "(1 OR (2 * 3))"
    assert associativity("1 OR 2 / 3") == "(1 OR (2 / 3))"
    assert associativity("1 OR 2 AND 3") == "(1 OR (2 AND 3))"
    assert associativity("1 OR 2 OR 3") == "((1 OR 2) OR 3)"
  end

  test "NOT binds looser than comparisons and tighter than AND" do
    assert associativity("NOT a = b") == "(NOT (a = b))"
    assert associativity("NOT a != b") == "(NOT (a != b))"
    assert associativity("NOT a < b + 1") == "(NOT (a < (b + 1)))"
    assert associativity("NOT a IS NULL") == "(NOT (a IS null))"
    assert associativity("NOT a IS NOT NULL") == "(NOT (a IS NOT null))"
    assert associativity("NOT a IN [1, 2]") == "(NOT (a IN [1, 2]))"
    assert associativity("NOT a LIKE 'x%'") == "(NOT (a LIKE 'x%'))"
    assert associativity("NOT a ILIKE 'x%'") == "(NOT (a ILIKE 'x%'))"
    assert associativity("NOT a RLIKE 'x'") == "(NOT (a RLIKE 'x'))"
    assert associativity("NOT a NOT LIKE 'x%'") == "(NOT (a NOT LIKE 'x%'))"
    assert associativity("NOT a NOT IN [1]") == "(NOT (a NOT IN [1]))"
    assert associativity("NOT a BETWEEN 1 AND 2") == "(NOT (a BETWEEN 1 AND 2))"
    assert associativity("NOT NOT a = b") == "(NOT (NOT (a = b)))"
    assert associativity("NOT a AND b") == "((NOT a) AND b)"
    assert associativity("NOT a OR b") == "((NOT a) OR b)"
    assert associativity("a AND NOT b = c") == "(a AND (NOT (b = c)))"
    assert associativity("(NOT a) = b") == "((NOT a) = b)"
    assert associativity("a = NOT b = c") == "(a = (NOT (b = c)))"

    assert associativity("CASE WHEN NOT a BETWEEN 1 AND 2 THEN 1 END AND b") ==
             "(CASE WHEN (NOT (a BETWEEN 1 AND 2)) THEN 1 END AND b)"
  end

  test "comparisons bind looser than arithmetic and tighter than AND and OR" do
    assert associativity("a = b + 1") == "(a = (b + 1))"
    assert associativity("a * 2 < b") == "((a * 2) < b)"
    assert associativity("a || b = c") == "((a || b) = c)"
    assert associativity("a = b || c") == "(a = (b || c))"
    assert associativity("a < b AND c") == "((a < b) AND c)"
    assert associativity("a OR b >= c") == "(a OR (b >= c))"
    assert associativity("a <=> b OR c != d") == "((a <=> b) OR (c != d))"
    assert associativity("a IS b AND c") == "((a IS b) AND c)"
    assert associativity("a IS NOT b OR c") == "((a IS NOT b) OR c)"
    assert associativity("a IN [1] OR b") == "((a IN [1]) OR b)"
    assert associativity("a NOT IN [1] AND b") == "((a NOT IN [1]) AND b)"
    assert associativity("a NOT IN [1] = b") == "((a NOT IN [1]) = b)"
    assert associativity("a LIKE 'x' AND b") == "((a LIKE 'x') AND b)"
    assert associativity("a NOT ILIKE 'x' AND b") == "((a NOT ILIKE 'x') AND b)"
    assert associativity("a RLIKE 'x' OR b") == "((a RLIKE 'x') OR b)"
    assert associativity("a NOT RLIKE 'x' AND b") == "((a NOT RLIKE 'x') AND b)"
  end

  test "comparisons of one tier associate to the left" do
    assert associativity("a = b < c") == "((a = b) < c)"
    assert associativity("a < b = c") == "((a < b) = c)"
    assert associativity("a IS b = c") == "((a IS b) = c)"
    assert associativity("a = b IS c") == "((a = b) IS c)"
    assert associativity("a LIKE b IN c") == "((a LIKE b) IN c)"
    assert associativity("a IS NOT b IS c") == "((a IS NOT b) IS c)"
  end

  test "BETWEEN binds looser than comparisons and tighter than AND" do
    assert associativity("a = b BETWEEN 1 AND 2") == "((a = b) BETWEEN 1 AND 2)"
    assert associativity("a BETWEEN 1 AND 2 AND b") == "((a BETWEEN 1 AND 2) AND b)"
    assert associativity("a BETWEEN b + 1 AND c * 2") == "(a BETWEEN (b + 1) AND (c * 2))"
    assert associativity("a BETWEEN b = 1 AND c") == "(a BETWEEN (b = 1) AND c)"
  end

  test "unary minus covers multiplication but not addition" do
    assert associativity("-a * b") == "- (a * b)"
    assert associativity("-a + b") == "(- a + b)"
    assert associativity("a * -b + c") == "((a * - b) + c)"
  end

  test "AS, ASC and DESC bind loosest" do
    assert associativity("a + b AS c") == "((a + b) AS c)"
    assert associativity("a OR b AS c") == "((a OR b) AS c)"
    assert associativity("a = b DESC") == "(a = b) DESC"
    assert associativity("a OR b ASC") == "(a OR b) ASC"
    assert associativity("a AS b OR c") == "(a AS (b OR c))"
    assert associativity("a AS b DESC") == "(a AS b) DESC"
    assert associativity("a BETWEEN 1 AND 2 OR b") == "((a BETWEEN 1 AND 2) OR b)"
    assert associativity("a OR b BETWEEN 1 AND 2") == "(a OR (b BETWEEN 1 AND 2))"
    assert associativity("a IS b IS NOT c") == "((a IS b) IS NOT c)"
  end

  test "every infix operator parses into its node and unparses as written" do
    operators = [
      {"*", MultiplyOperator},
      {"/", Guardian.AST.Node.Operators.DivideOperator},
      {"+", AddOperator},
      {"-", Guardian.AST.Node.Operators.SubtractOperator},
      {"||", Guardian.AST.Node.Operators.ConcatOperator},
      {"<", Guardian.AST.Node.Operators.LessThanOperator},
      {"<=", Guardian.AST.Node.Operators.LessThanOrEqualOperator},
      {">", Guardian.AST.Node.Operators.GreaterThanOperator},
      {">=", Guardian.AST.Node.Operators.GreaterThanOrEqualOperator},
      {"<=>", Guardian.AST.Node.Operators.NullSafeEqualOperator},
      {"=", EqualOperator},
      {"!=", Guardian.AST.Node.Operators.NotEqualOperator},
      {"IS", IsOperator},
      {"IS NOT", Guardian.AST.Node.Operators.IsNotOperator},
      {"LIKE", Guardian.AST.Node.Operators.LikeOperator},
      {"ILIKE", Guardian.AST.Node.Operators.IlikeOperator},
      {"NOT LIKE", Guardian.AST.Node.Operators.NotLikeOperator},
      {"NOT ILIKE", Guardian.AST.Node.Operators.NotIlikeOperator},
      {"IN", Guardian.AST.Node.Operators.InOperator},
      {"NOT IN", Guardian.AST.Node.Operators.NotInOperator},
      {"AND", AndOperator},
      {"OR", Guardian.AST.Node.Operators.OrOperator},
      {"AS", Guardian.AST.Node.As},
    ]

    for {symbol, module} <- operators do
      source = "a #{symbol} b"

      assert %^module{
               left: %Guardian.AST.Node.Identifier{name: "a"},
               right: %Guardian.AST.Node.Identifier{name: "b"},
             } = parse(source)

      assert Guardian.AST.unparse(parse(source)) == source
    end

    for {symbol, module} <- [
          {"RLIKE", RlikeOperator},
          {"NOT RLIKE", Guardian.AST.Node.Operators.NotRlikeOperator},
        ] do
      source = "a #{symbol} 'x'"
      assert %^module{right: %Guardian.AST.Node.Literal{value: "x"}} = parse(source)
      assert Guardian.AST.unparse(parse(source)) == source
    end

    assert %BetweenOperator{} = parse("a BETWEEN 1 AND 2")
    assert Guardian.AST.unparse(parse("a BETWEEN 1 AND 2")) == "a BETWEEN 1 AND 2"

    assert %Guardian.AST.Node.Ascending{left: %Guardian.AST.Node.Identifier{name: "a"}} =
             parse("a ASC")

    assert Guardian.AST.unparse(parse("a ASC")) == "a ASC"

    assert %Guardian.AST.Node.Descending{left: %Guardian.AST.Node.Identifier{name: "a"}} =
             parse("a DESC")

    assert Guardian.AST.unparse(parse("a DESC")) == "a DESC"
  end

  test "an incomplete operator is an error at the missing operand" do
    for {source, reason, col} <- [
          {"a IS NOT", "Expected expression, got end of input", 8},
          {"a IS", "Expected expression, got end of input", 4},
          {"a NOT LIKE", "Expected expression, got end of input", 10},
          {"a NOT", "Expected end of input, got NOT", 2},
          {"a AS", "Expected expression, got end of input", 4},
          {"a IN", "Expected expression, got end of input", 4},
          {"a NOT IN", "Expected expression, got end of input", 8},
          {"a BETWEEN 1", "Expected AND keyword, got end of input", 11},
          {"a BETWEEN 1 OR 2", "Expected AND keyword, got OR", 12},
          {"a BETWEEN 1 AND", "Expected expression, got end of input", 15},
          {"a RLIKE 1", "Expected string literal, got 1", 8},
          {"a NOT RLIKE b", "Expected string literal, got b", 12},
          {"a NOT RLIKE '['", "Invalid regular expression", 12},
          {"a = ", "Expected expression, got end of input", 4},
          {"a BETWEEN 1 2", "Expected AND keyword, got 2", 12},
          {"a DESC b", "Expected end of input, got b", 7},
          {"select a order by a desc b", "Expected end of statement, got b", 25},
        ] do
      assert %ParseError{reason: ^reason, col: ^col} = parse_failure(source)
    end
  end

  test "IN and NOT IN reject a parenthesized list at the parenthesis, allow a grouped operand" do
    reason = "IN takes a list in square brackets, as in x IN ['a', 'b']"

    for source <- [
          "a IN ('x')",
          "a IN (1)",
          "a IN (-1)",
          "a IN (null)",
          "a IN (('x'))",
          "a IN (-(1))",
          "a IN ('a', 'b')",
          "a IN (b, c)",
          "a IN ()",
          "a IN ( 'x' ) OR b",
        ] do
      assert %ParseError{reason: ^reason, col: 5} = parse_failure(source)
    end

    for source <- ["a NOT IN ('x')", "a NOT IN ('a', 'b')", "a NOT IN ()"] do
      assert %ParseError{reason: ^reason, col: 9} = parse_failure(source)
    end

    assert %ParseError{reason: ^reason, row: 1, col: 11} =
             parse_failure("select a\nwhere a IN ('x')")

    for source <- [
          "a IN [1]",
          "1 IN ([1])",
          "a IN (b)",
          "a IN (b || c)",
          "a IN ('x' || 'y')",
          "a IN (CASE WHEN c THEN [1] ELSE [2] END)",
        ] do
      assert %InOperator{} = parse(source)
    end

    assert %NotInOperator{} = parse("a NOT IN (b)")

    assert associativity("a IN (b) OR c") == "((a IN (b)) OR c)"
    assert associativity("a IN (b) || c") == "(a IN ((b) || c))"
    assert associativity("a IN (b) IS NULL") == "((a IN (b)) IS null)"
    assert associativity("a IN (b) = c") == "((a IN (b)) = c)"
  end

  test "nested grouped IN operands parse in linear time" do
    nested =
      Enum.reduce(1..200, "[1]", fn i, acc ->
        "(a #{if rem(i, 2) == 0, do: "IN", else: "NOT IN"} #{acc})"
      end)

    {micros, expr} = :timer.tc(fn -> parse("b IN #{nested}") end)
    assert %InOperator{} = expr
    assert micros < 5_000_000
  end

  test "a standalone rewritten negation unparses to text that parses back to it" do
    for source <- [
          "a NOT LIKE 'x%'",
          "a NOT ILIKE 'x%'",
          "a NOT RLIKE 'x'",
          "a IS NOT b",
          "a NOT IN [1]",
        ] do
      %module{} = expr = parse(source)
      rewritten = module.rewrite(expr)
      assert parse(Guardian.AST.unparse(rewritten)) == rewritten
    end
  end

  defp associativity(source) do
    parse(source)
    |> wrap_binary_operators_in_parentheses()
    |> Guardian.AST.unparse()
  end

  defp wrap_binary_operators_in_parentheses(expr) do
    Guardian.AST.postwalk(expr, fn
      %{left: _, right: _} = expr ->
        %Guardian.AST.Node.Parentheses{expr: expr}

      %struct{} = expr when struct in [NotOperator, BetweenOperator] ->
        %Guardian.AST.Node.Parentheses{expr: expr}

      %Guardian.AST.Node.Parentheses{expr: %Guardian.AST.Node.Parentheses{expr: expr}} ->
        %Guardian.AST.Node.Parentheses{expr: expr}

      expr ->
        expr
    end)
  end
end
