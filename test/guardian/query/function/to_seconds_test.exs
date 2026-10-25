defmodule Guardian.Query.Function.ToSecondsTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "to_seconds function" do
    assert eval("to_seconds('2024-01-02 03:04:05')") === 1_704_164_645
  end

  test "to_seconds gives null for values that are not canonical UTC timestamps" do
    for value <- [
          "2024-02-30 00:00:00",
          "2024-13-01 00:00:00",
          "2024-01-02T03:04:05",
          "2024-01-02 03:04:05Z",
          "2024-01-02 03:04:05+00:00",
          "invalid",
          123,
          nil,
        ] do
      assert eval("to_seconds(value)", value: value) === nil, inspect(value)
    end
  end
end
