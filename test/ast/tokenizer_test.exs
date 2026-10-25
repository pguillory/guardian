defmodule Guardian.TokenizerTest do
  import Guardian.AST.Tokenizer
  alias Guardian.AST.ParseError
  use ExUnit.Case, async: true

  test "tokenize" do
    assert tokenize("null") == [null: nil]
    assert tokenize("false") == [false: false]
    assert tokenize("true") == [true: true]
    assert tokenize("123") == [integer: 123]
    assert tokenize("1.2") == [float: 1.2]
    assert tokenize("1.") == [float: 1.0]
    assert tokenize("1. + 2") == [float: 1.0, punctuation: "+", integer: 2]
    assert tokenize("1e20") == [float: 1.0e20]
    assert tokenize("1.e5") == [float: 1.0e5]
    assert tokenize("1E+3") == [float: 1.0e3]
    assert tokenize("1.5e-3") == [float: 1.5e-3]
    assert tokenize("1e-400") == [float: 0.0]
    assert tokenize("1e") == [integer: 1, identifier: "e"]
    assert tokenize("1e+") == [integer: 1, identifier: "e", punctuation: "+"]
    assert tokenize("1end") == [integer: 1, keyword: "END"]

    assert %ParseError{reason: "Number out of range", col: 2} =
             catch_error(tokenize("1 1e400"))

    assert tokenize("'abc'") == [string: "abc"]
    assert tokenize("foo") == [identifier: "foo"]
    assert tokenize(",") == [punctuation: ","]
    assert tokenize("+") == [punctuation: "+"]
    assert tokenize("(1)") == [punctuation: "(", integer: 1, punctuation: ")"]
    assert tokenize("1 + 2") == [integer: 1, punctuation: "+", integer: 2]
    assert tokenize("1 - 2") == [integer: 1, punctuation: "-", integer: 2]
    assert tokenize("1 * 2") == [integer: 1, punctuation: "*", integer: 2]
    assert tokenize("1 / 2") == [integer: 1, punctuation: "/", integer: 2]
    assert tokenize("1 < 2") == [integer: 1, punctuation: "<", integer: 2]
    assert tokenize("1 <= 2") == [integer: 1, punctuation: "<=", integer: 2]
    assert tokenize("1 > 2") == [integer: 1, punctuation: ">", integer: 2]
    assert tokenize("1 >= 2") == [integer: 1, punctuation: ">=", integer: 2]
    assert tokenize("1 <=> 2") == [integer: 1, punctuation: "<=>", integer: 2]
    assert tokenize("1 = 2") == [integer: 1, punctuation: "=", integer: 2]
    assert tokenize("1 != 2") == [integer: 1, punctuation: "!=", integer: 2]
  end

  test "tokenize dotted field paths" do
    assert tokenize("user.name") == [identifier: "user.name"]
    assert tokenize("a.b.c") == [identifier: "a.b.c"]
    assert tokenize("users..name") == [identifier: "users..name"]
    assert tokenize("users..orders..id") == [identifier: "users..orders..id"]
    assert tokenize("a..b.c") == [identifier: "a..b.c"]
    assert tokenize("User.Name") == [identifier: "user.name"]
    assert tokenize("items.0") == [identifier: "items.0"]
    assert tokenize("_a._b") == [identifier: "_a._b"]

    # Keywords and literals are only special as whole tokens.
    assert tokenize("order.id") == [identifier: "order.id"]
    assert tokenize("user.desc") == [identifier: "user.desc"]
    assert tokenize("null.x") == [identifier: "null.x"]

    assert tokenize("a.b + 1") == [identifier: "a.b", punctuation: "+", integer: 1]

    assert tokenize("f(a.b,c.d)") == [
             identifier: "f",
             punctuation: "(",
             identifier: "a.b",
             punctuation: ",",
             identifier: "c.d",
             punctuation: ")",
           ]

    assert tokenize("1.5") == [float: 1.5]
    assert_raise ParseError, fn -> tokenize("a.") end
    assert_raise ParseError, fn -> tokenize("a..") end
    assert tokenize("a...b") == [identifier: "a...b"]
    assert tokenize("a....b") == [identifier: "a....b"]
    assert_raise ParseError, fn -> tokenize("a...") end
    assert_raise ParseError, fn -> tokenize("select.") end
    assert_raise ParseError, fn -> tokenize("a . b") end
    assert_raise ParseError, fn -> tokenize(".a") end
  end

  test "tokenize_raw" do
    assert tokenize_raw("1 + 2") == [
             integer: "1",
             whitespace: " ",
             punctuation: "+",
             whitespace: " ",
             integer: "2",
           ]

    # A comment owns its newline; one at the end of input runs to the end.
    assert tokenize_raw("1--x") == [integer: "1", comment: "--x"]
    assert tokenize_raw("1--x\n2") == [integer: "1", comment: "--x\n", integer: "2"]
  end

  test "position" do
    source = """
    SELECT 1
    FROM x
    """

    tokens = tokenize(source)
    assert tokens == [keyword: "SELECT", integer: 1, keyword: "FROM", identifier: "x"]

    assert position(source, keyword: "SELECT", integer: 1, keyword: "FROM", identifier: "x") ==
             {0, 0}

    assert position(source, integer: 1, keyword: "FROM", identifier: "x") == {0, 7}
    assert position(source, keyword: "FROM", identifier: "x") == {1, 0}
    assert position(source, identifier: "x") == {1, 5}
    assert position(source, []) == {2, 0}
  end

  test "truncate_after_semicolon" do
    assert truncate_after_semicolon("12; 34;") == "12"
    assert truncate_after_semicolon("12; 34;", 0, 0) == "12"
    assert truncate_after_semicolon("12; 34;", 0, 1) == "12"
    assert truncate_after_semicolon("12; 34;", 0, 2) == "12"
    assert truncate_after_semicolon("12; 34;", 0, 3) == "12"
    assert truncate_after_semicolon("12; 34;", 0, 4) == "12; 34"
    assert truncate_after_semicolon("12; 34;", 0, 5) == "12; 34"
    assert truncate_after_semicolon("12; 34;", 0, 6) == "12; 34"

    assert truncate_after_semicolon("select 1; select 2;") == "select 1"
    assert truncate_after_semicolon("select 1; select 2;", 0, 0) == "select 1"
    assert truncate_after_semicolon("select 1; select 2;", 0, 1) == "select 1"
    assert truncate_after_semicolon("select 1; select 2;", 0, 2) == "select 1"
    assert truncate_after_semicolon("select 1; select 2;", 0, 3) == "select 1"
    assert truncate_after_semicolon("select 1; select 2;", 0, 4) == "select 1"
    assert truncate_after_semicolon("select 1; select 2;", 0, 5) == "select 1"
    assert truncate_after_semicolon("select 1; select 2;", 0, 6) == "select 1"
    assert truncate_after_semicolon("select 1; select 2;", 0, 7) == "select 1"
    assert truncate_after_semicolon("select 1; select 2;", 0, 8) == "select 1"
    assert truncate_after_semicolon("select 1; select 2;", 0, 9) == "select 1"
    assert truncate_after_semicolon("select 1; select 2;", 0, 10) == "select 1; select 2"
    assert truncate_after_semicolon("select 1; select 2;", 0, 12) == "select 1; select 2"
    assert truncate_after_semicolon("select 1; select 2;", 0, 13) == "select 1; select 2"
    assert truncate_after_semicolon("select 1; select 2;", 0, 14) == "select 1; select 2"
    assert truncate_after_semicolon("select 1; select 2;", 0, 15) == "select 1; select 2"
    assert truncate_after_semicolon("select 1; select 2;", 0, 16) == "select 1; select 2"
    assert truncate_after_semicolon("select 1; select 2;", 0, 17) == "select 1; select 2"
    assert truncate_after_semicolon("select 1; select 2;", 0, 18) == "select 1; select 2"
    assert truncate_after_semicolon("select 1; select 2;", 0, 19) == "select 1; select 2;"
  end

  test "error reasons and positions" do
    # {source, reason, row, col}; col counts bytes, and only \n starts a row.
    for {source, reason, row, col} <- [
          {"SELECT #", "Unexpected character", 0, 7},
          {"SELECT 1\n  #", "Unexpected character", 1, 2},
          {"SELECT 'é' #", "Unexpected character", 0, 12},
          {"SELECT 'a", "Unterminated string literal", 0, 7},
          {"SELECT 1,\n 'a\\'", "Unterminated string literal", 1, 1},
          {"SELECT 'a\\", "Unterminated string literal", 0, 7},
          {"SELECT 1e400", "Number out of range", 0, 7},
          {"SELECT 'é', 1e400", "Number out of range", 0, 13},
          {"SELECT 1\n, 2e999", "Number out of range", 1, 2},
          {"SELECT 'a\\q'", "Bad escaped character", 0, 9},
          {"SELECT 'x', 'ab\\uzzzz'", "Invalid \\u escape", 0, 15},
          {"SELECT\n'é\\u12'", "Bad escaped character", 1, 3},
          {"SELECT '\\u123'", "Bad escaped character", 0, 8},
          {"SELECT 'a\\uD801\\uDC3'", "Invalid UTF-16 codepoint", 0, 9},
          {"SELECT 'a\\uDC37'", "Invalid UTF-16 codepoint", 0, 9},
          {"SELECT 'a\\uD801b'", "Invalid UTF-16 codepoint", 0, 9},
          {"SELECT 1\r\n\t'\\q'", "Bad escaped character", 1, 2},
          {"SELECT 'a\nb\\q'", "Bad escaped character", 1, 1},
          {"SELECT '\\n\\uzzzz'", "Invalid \\u escape", 0, 10},
          {<<"SELECT 1, '", 0xFF, "'">>, "Invalid UTF-8 in string literal", 0, 10},
          # A bad escape wins over invalid UTF-8 in the same literal.
          {<<"SELECT '", 0xFF, "\\q'">>, "Bad escaped character", 0, 9},
          # The whole source is scanned before any token is evaluated, so a later
          # scanner error wins over an earlier evaluation error.
          {"SELECT 1e400 #", "Unexpected character", 0, 13},
          {"SELECT '\\q' #", "Unexpected character", 0, 12},
          {"SELECT 99999999999999999999 #", "Unexpected character", 0, 28},
          # An integer literal outside int64 is reported at the start of its raw token,
          # leading zeros included.
          {"SELECT 9223372036854775808", "Number out of range", 0, 7},
          {"SELECT 'é', 9223372036854775808", "Number out of range", 0, 13},
          {"SELECT 1\n, 0009223372036854775808", "Number out of range", 1, 2},
          {"SELECT -9223372036854775808", "Number out of range", 0, 8},
        ] do
      assert catch_error(tokenize(source)) == %ParseError{reason: reason, row: row, col: col},
             inspect(source)
    end
  end

  test "integer literals are unsigned int64" do
    max = 9_223_372_036_854_775_807
    assert tokenize("9223372036854775807") == [integer: max]
    assert tokenize("0009223372036854775807") == [integer: max]
    assert tokenize("9223372036854775806") == [integer: max - 1]
    assert tokenize("0000000000000000000001") == [integer: 1]
    assert tokenize("000") == [integer: 0]
    assert tokenize(String.duplicate("0", 100)) == [integer: 0]
    assert tokenize("-9223372036854775807") == [punctuation: "-", integer: max]

    for source <- [
          "9223372036854775808",
          "0009223372036854775808",
          "9999999999999999999",
          "10000000000000000000",
          "99999999999999999999",
          "1234567890123456789012345",
        ] do
      assert %ParseError{reason: "Number out of range", row: 0, col: 0} =
               catch_error(tokenize(source)),
             source
    end
  end

  test "a huge integer literal is rejected without converting it" do
    source = String.duplicate("9", 1_000_000)
    {micros, error} = :timer.tc(fn -> catch_error(tokenize(source)) end)
    assert %ParseError{reason: "Number out of range", col: 0} = error
    assert micros < 1_000_000
  end

  test "errors" do
    assert catch_error(tokenize("SELECT 'a")) == %ParseError{
             reason: "Unterminated string literal",
             row: 0,
             col: 7,
           }
  end
end
