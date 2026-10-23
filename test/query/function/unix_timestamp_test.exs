defmodule Query.Function.UnixTimestampTest do
  use Query.EvaluationTestCase, async: true

  test "unix_timestamp function" do
    assert eval("unix_timestamp('2024-01-02 03:04:05')") === 1_704_164_645
  end
end
