defmodule Query.TextTest do
  # The string cap, truncation and string forms (Query.Text), and the functions the
  # cap applies to.
  use Query.EvaluationTestCase, async: true

  alias Query.Text

  @max Text.max_bytes()

  describe "truncate/2" do
    test "keeps short strings whole and cuts at a character boundary" do
      assert Text.truncate("abc", 3) == {"abc", false}
      assert Text.truncate("abcd", 3) == {"abc", true}
      assert Text.truncate("aé", 2) == {"a", true}
      assert Text.truncate("a😀", 4) == {"a", true}
      # Invalid UTF-8 is cut near the byte limit (up to three bytes short).
      {cut, true} = Text.truncate(:binary.copy(<<0xFF>>, 10), 5)
      assert byte_size(cut) in 2..5
    end

    test "returns a copy, never a sub-binary of a larger string" do
      big = String.duplicate("a", 100_000)
      {cut, true} = Text.truncate(big, 10)
      assert :binary.referenced_byte_size(cut) == 10
    end
  end

  describe "form/2" do
    test "renders each kind of value" do
      assert Text.form(nil, 100) == nil
      assert Text.form("a\"b", 100) == "a\"b"
      assert Text.form(-12, 100) == "-12"
      assert Text.form(0.1, 100) == "0.1"
      assert Text.form(false, 100) == "false"
      assert Text.form([1, [nil, "x\"y"], 2.5e-7], 100) == ~S([1,[null,"x\"y"],2.5e-7])
    end

    test "stops at the budget, also inside a huge nested list" do
      list = List.duplicate(List.duplicate("abcdef", 1_000), 1_000)
      {micros, form} = :timer.tc(fn -> Text.form(list, 100) end)

      assert form ==
               binary_part(
                 ~s([["abcdef","abcdef",) <> String.duplicate(~s("abcdef",), 20),
                 0,
                 100
               )

      assert micros < 100_000
      assert Text.form(["é"], 3) == ~s([")
      assert Text.form(["é"], 4) == ~s(["é)
      # Escapes and U+FFFD lengthen a string; the cut falls on the rendered text.
      assert Text.form([~s(a"b)], 4) == ~s(["a\\)
      assert Text.form([<<0xFF>>], 4) == ~s([")
      assert Text.form([<<0xFF>>], 5) == ~s(["\uFFFD)
      assert Text.form_cut([1, 2], 5) == {"[1,2]", false}
      assert Text.form_cut([1, 2], 4) == {"[1,2", true}
    end
  end

  describe "the cap" do
    test "concat and || render lists and stop at the cap" do
      assert eval("concat(a, b)", a: [1, "a"], b: nil) == ~s([1,"a"])
      assert eval("a || b", a: "x", b: [[1.5], []]) == "x[[1.5],[]]"
      assert eval("concat(a, b, c)", a: 1, b: true, c: 2.5) == "1true2.5"

      half = String.duplicate("é", div(@max, 4))
      assert eval("concat(a, a, a)", a: half) == half <> half
      # A cut that would split é keeps the whole characters before it.
      assert eval("concat(a, b)", a: "x", b: String.duplicate("é", div(@max, 2))) ==
               "x" <> String.duplicate("é", div(@max, 2) - 1)
    end

    test "a cut ends the join: nothing after it fills the bytes a split character freed" do
      a = String.duplicate("a", @max - 1) <> "é"
      cut = String.duplicate("a", @max - 1)
      assert eval("concat(a, 'b')", a: a) == cut
      assert eval("a || 'b'", a: a) == cut
      assert eval("concat(c, 'é', 'b')", c: cut) == cut
      assert eval("c || 'é' || 'b'", c: cut) == cut
      assert eval("concat(c, null, 'b')", c: cut) == cut <> "b"
      # A list cut by the cap ends it too: "[1]" has room for its "[" only.
      assert eval("concat(c, l, 'b')", c: cut, l: [1]) == cut <> "["
    end

    test "replace cuts a long replacement or slice before appending it" do
      huge = String.duplicate("x", 4 * @max)
      assert eval("replace('a', 'a', r)", r: huge) == binary_part(huge, 0, @max)
      assert eval("replace(s, 'b$', 'c')", s: huge <> "b") == binary_part(huge, 0, @max)
      # Nothing follows a cut replacement.
      r = String.duplicate("é", div(@max, 2))
      assert eval("replace('za', 'a', r)", r: r) == "z" <> binary_part(r, 0, @max - 2)
      assert eval("replace('zab', 'a', r)", r: r) == "z" <> binary_part(r, 0, @max - 2)
    end

    test "lpad and rpad stop at the cap, at a character boundary" do
      assert eval("lpad(a, b)", a: "é", b: @max - 1) == String.duplicate(" ", @max - 2) <> "é"
      # One more space leaves no room for the whole é.
      assert eval("lpad(a, b)", a: "é", b: @max) == String.duplicate(" ", @max - 1)
      assert eval("lpad(a, b)", a: "é", b: @max + 1) == String.duplicate(" ", @max)
      assert eval("rpad(a, b)", a: "é", b: @max - 1) == "é" <> String.duplicate(" ", @max - 2)
      assert eval("rpad(a, b)", a: "é", b: @max) == "é" <> String.duplicate(" ", @max - 2)
      # A long value is cut after the padding.
      long = String.duplicate("a", @max + 10)
      assert eval("lpad(a, b)", a: long, b: @max + 12) == "  " <> binary_part(long, 0, @max - 2)
      # A value already longer than the size comes back whole.
      assert eval("lpad(a, b)", a: long, b: 5) == long
      # One that needs padding is cut, and no padding follows the cut.
      assert eval("rpad(a, b)", a: long, b: @max + 20) == binary_part(long, 0, @max)
      split = String.duplicate("a", @max - 1) <> "é"
      assert eval("rpad(a, b)", a: split, b: @max + 5) == String.duplicate("a", @max - 1)
    end

    test "lower, upper and normalize cut what case mapping or normalization lengthens" do
      # Each is three bytes from two: ŉ uppercases to ʼN, İ lowercases to i̇, NFD é is
      # e and a combining accent.
      for {function, char, expected} <- [
            {"upper", "ŉ", "ʼN"},
            {"lower", "İ", "i̇"},
            {"normalize(a, 'NFD')", "é", "é"},
          ] do
        source = if function =~ "(", do: function, else: "#{function}(a)"
        value = String.duplicate(char, div(@max, 2))
        result = eval(source, a: value)
        assert byte_size(result) <= @max
        assert String.starts_with?(result, expected)
        assert String.valid?(result)
        assert eval(source, a: char) == expected
      end
    end

    test "format_timestamp cuts a long format's output" do
      format = String.duplicate("MMMM", @max)
      result = eval("format_timestamp(a, b)", a: "2026-09-01 00:00:00", b: format)
      assert byte_size(result) == @max
      assert String.starts_with?(result, "SeptemberSeptember")
    end
  end
end
