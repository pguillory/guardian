defmodule Guardian.Query.Function.IpToIntegerTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "ip_to_integer function" do
    assert eval("ip_to_integer('127.0.0.1')") === 127 * 256 * 256 * 256 + 1
    assert eval("ip_to_integer('foo')") === nil
    assert eval("ip_to_integer(nil)") === nil
  end

  test "a string over 64 bytes is null without being parsed" do
    padded = String.duplicate("0", 64 - byte_size("1.0.0.1")) <> "1.0.0.1"
    assert eval("ip_to_integer(a)", a: padded) === 1 * 256 * 256 * 256 + 1
    assert eval("ip_to_integer(a)", a: "0" <> padded) === nil

    huge = String.duplicate("0", 16 * 1024 * 1024) <> "1.0.0.1"
    assert eval("ip_to_integer(a)", a: huge) === nil
  end
end
