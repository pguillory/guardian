defmodule TimestampTest do
  import Timestamp
  use ExUnit.Case, async: true

  test "to_seconds" do
    assert to_seconds("2024-03-06 18:26:45") == 1_709_749_605
  end

  test "from_seconds" do
    assert from_seconds(1_709_749_605) == "2024-03-06 18:26:45"
  end

  test "from_string" do
    assert from_string("2024-04-08T19:35:44.747035Z") == {:ok, "2024-04-08 19:35:44"}
    assert from_string("2024-04-08 19:37:13.870187") == {:ok, "2024-04-08 19:37:13"}
    assert from_string("2024-04-08 19:37:13") == {:ok, "2024-04-08 19:37:13"}
    assert from_string("2024-04-08T19:40:40.011Z") == {:ok, "2024-04-08 19:40:40"}
    assert from_string("invalid") == :error
  end
end
