defmodule Query.Function.ToStringTest do
  use Query.EvaluationTestCase, async: true

  @max Query.Text.max_bytes()

  test "to_string gives every value's string form, and null for null" do
    assert eval("to_string(x)", x: nil) === nil
    assert eval("to_string(x)", x: false) === "false"
    assert eval("to_string(x)", x: true) === "true"
    assert eval("to_string(x)", x: 123) === "123"
    assert eval("to_string(x)", x: -9_223_372_036_854_775_808) === "-9223372036854775808"
    assert eval("to_string(x)", x: 4.5) === "4.5"
    assert eval("to_string(x)", x: 1.0e300) === "1.0e300"
    assert eval("to_string(x)", x: "abc") === "abc"
    assert eval("to_string(x)", x: []) === "[]"
    assert eval("to_string(x)", x: [1, nil, "a", true]) === ~s([1,null,"a",true])
    assert eval("to_string(x)", x: [[2.5], []]) === "[[2.5],[]]"
  end

  test "strings in a list are quoted and escaped as JSON, invalid UTF-8 as U+FFFD" do
    assert eval("to_string(x)", x: [~s(say "hi"\\), "a\nb\u0001"]) ===
             ~S(["say \"hi\"\\","a\nb\u0001"])

    assert eval("to_string(x)", x: [<<?a, 0xFF, ?b>>]) === ~s(["a\uFFFDb"])
    # Outside a list a string is returned as it is, invalid or not.
    assert eval("to_string(x)", x: <<0xFF>>) === <<0xFF>>
  end

  test "a string is returned whole; a list's form stops at the string cap" do
    long = String.duplicate("é", @max)
    assert eval("to_string(x)", x: long) === long

    form = eval("to_string(x)", x: List.duplicate(123_456_789, 100_000))
    assert byte_size(form) == @max
    assert String.starts_with?(form, "[123456789,123456789,")

    # Cut at a character boundary.
    form = eval("to_string(x)", x: [String.duplicate("é", @max)])
    assert String.valid?(form) and byte_size(form) in (@max - 1)..@max
  end

  test "over a column, all strings and nulls pass through, other values render" do
    assert eval_segment_and_rows("to_string(x)", [%{x: "a"}, %{x: nil}]) ==
             {["a", nil], ["a", nil]}

    assert eval_segment_and_rows("to_string(x)", [%{x: "a"}, %{x: 1}, %{x: [1]}, %{x: nil}]) ==
             {["a", "1", "[1]", nil], ["a", "1", "[1]", nil]}
  end
end
