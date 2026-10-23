defmodule Query.Function.IpToIntegerTest do
  use Query.EvaluationTestCase, async: true

  test "ip_to_integer function" do
    assert eval("ip_to_integer('127.0.0.1')") === 127 * 256 * 256 * 256 + 1
    assert eval("ip_to_integer('foo')") === nil
    assert eval("ip_to_integer(nil)") === nil
  end
end
