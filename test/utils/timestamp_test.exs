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

  test "from_string and to_seconds apply a UTC offset" do
    for string <- [
          "2020-01-01T19:35:00+02:00",
          "2020-01-01 19:35:00+0200",
          "2020-01-01T19:35:00+02",
          "2020-01-01T12:05:00-05:30",
          "2020-01-01T17:35:00Z",
          "2020-01-01T17:35:00.999Z",
          "2020-01-01 17:35:00",
        ] do
      assert from_string(string) == {:ok, "2020-01-01 17:35:00"}, string
      assert to_seconds(string) == to_seconds("2020-01-01 17:35:00"), string
    end

    # An offset can cross a day, month and year boundary.
    assert from_string("2021-01-01T01:00:00+03:00") == {:ok, "2020-12-31 22:00:00"}
  end

  test "an unreadable offset or a UTC time outside years 0000 to 9999 is an error" do
    for string <- [
          "2020-01-01T19:35:00+24:00",
          "2020-01-01T19:35:00+2",
          "0000-01-01T00:30:00+01:00",
          "9999-12-31T23:30:00-01:00",
        ] do
      assert from_string(string) == :error, string
      assert_raise ArgumentError, fn -> to_seconds(string) end
    end

    assert from_string("0000-01-01T01:00:00+01:00") == {:ok, "0000-01-01 00:00:00"}
    assert from_string("9999-12-31T22:59:59-01:00") == {:ok, "9999-12-31 23:59:59"}
  end
end
