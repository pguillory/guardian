defmodule AST.StringEncodingTest do
  import AST.StringEncoding
  use ExUnit.Case, async: true

  defp decode!(literal) do
    {:ok, string} = decode_string(literal)
    string
  end

  test "decode_string" do
    assert decode!(~S['']) == ""
    assert decode!(~S['abc']) == "abc"

    # https://en.wikipedia.org/wiki/UTF-16#U+D800_to_U+DFFF_(surrogates)
    assert decode!(~S['\u0024']) == AST.Unicode.utf8("U+0024")
    assert decode!(~S['\u20AC']) == AST.Unicode.utf8("U+20AC")
    assert decode!(~S['\uABEF']) == decode!(~S['\uabef'])
    assert decode!(~S['\uabef']) == AST.Unicode.utf8("U+ABEF")
    assert decode!(~S['\uD801\uDC37']) == AST.Unicode.utf8("U+10437")
    assert decode!(~S['\uD852\uDF62']) == AST.Unicode.utf8("U+24B62")

    # Adjacent escapes that are not a surrogate pair are separate characters.
    assert decode!(~S['\u0001\u0002']) == "\x01\x02"
    assert decode!(~S['\u0041\uD801\uDC37']) == "A" <> AST.Unicode.utf8("U+10437")
  end

  test "decode_string rejects a literal that is not valid UTF-8" do
    source = <<?', ?a, 0xFF, ?'>>

    assert decode_string(source) == {:error, "Invalid UTF-8 in string literal", 0}
    # A bad escape is reported first, at its own offset.
    assert decode_string(<<?', 0xFF, ?\\, ?q, ?'>>) == {:error, "Bad escaped character", 2}

    assert %AST.ParseError{reason: "Invalid UTF-8 in string literal", col: 7} =
             catch_error(Query.Resolver.resolve("SELECT " <> source))
  end

  test "decode_string rejects bad escapes at the escape's backslash" do
    # {source, reason, the rest of the literal from the bad escape}
    for {source, reason, remaining} <- [
          {~S['a\uzzzz'], ~S[Invalid \u escape], ~S[\uzzzz']},
          {~S['\u00g0'], ~S[Invalid \u escape], ~S[\u00g0']},
          {~S['\u+123'], ~S[Invalid \u escape], ~S[\u+123']},
          {~S['\u12'], "Bad escaped character", ~S[\u12']},
          {~S['\u123'], "Bad escaped character", ~S[\u123']},
          {~S['\q'], "Bad escaped character", ~S[\q']},
          {~S['\uD801'], "Invalid UTF-16 codepoint", ~S[\uD801']},
          {~S['\uD801x'], "Invalid UTF-16 codepoint", ~S[\uD801x']},
          {~S['\uD801\u0041'], "Invalid UTF-16 codepoint", ~S[\uD801\u0041']},
          {~S['\uD801\uzzzz'], "Invalid UTF-16 codepoint", ~S[\uD801\uzzzz']},
          {~S['\uD801\uDC3'], "Invalid UTF-16 codepoint", ~S[\uD801\uDC3']},
          {~S['a\uDC37'], "Invalid UTF-16 codepoint", ~S[\uDC37']},
          {~S['\uDC37\uD801'], "Invalid UTF-16 codepoint", ~S[\uDC37\uD801']},
        ] do
      assert decode_string(source) ==
               {:error, reason, byte_size(source) - byte_size(remaining)}
    end
  end

  test "encode_string output decodes to the original string" do
    controls = Enum.map(0x00..0x1F, &<<&1::utf8>>)

    strings =
      controls ++
        [
          Enum.join(controls),
          "\x01\x02",
          "\\",
          "a\\",
          "\\a",
          "a\\b",
          "\\\\",
          "'",
          "a'",
          "\\'",
          "'\\",
          "/",
          "\x7F",
          AST.Unicode.utf8("U+10437"),
          "é\n\\",
        ]

    for string <- strings do
      encoded = encode_string(string)
      assert decode_string(encoded) == {:ok, string}
      assert AST.Tokenizer.tokenize(encoded) == [string: string]
    end
  end

  test "encode_string" do
    assert encode_string("") == ~S['']
    assert encode_string("abc") == ~S['abc']

    # Control characters without a short escape are four lowercase hex digits; other
    # characters from U+0020 up (but quote, backslash and slash), supplementary ones
    # included, are written as is.
    assert encode_string("\x00\x1b\x1f") == ~S['\u0000\u001b\u001f']
    assert encode_string("\x7F") == "'\x7F'"
    assert encode_string(AST.Unicode.utf8("U+10437")) == "'" <> AST.Unicode.utf8("U+10437") <> "'"
  end
end
