defmodule Guardian.TimestampTest do
  import Guardian.Timestamp
  use ExUnit.Case, async: true

  test "to_seconds" do
    assert to_seconds("2024-03-06 18:26:45") == 1_709_749_605
  end

  test "parse_seconds gives the epoch seconds or :error without raising" do
    assert parse_seconds("2024-03-06 18:26:45") == {:ok, 1_709_749_605}
    assert parse_seconds("1970-01-01 00:00:00") == {:ok, 0}

    assert parse_seconds("0000-01-01 00:00:00") == {:ok, -62_167_219_200}
    assert parse_seconds("9999-12-31 23:59:59") == {:ok, 253_402_300_799}
  end

  test "from_seconds" do
    assert from_seconds(1_709_749_605) == "2024-03-06 18:26:45"
  end

  test "from_string" do
    assert from_string("2024-04-08 19:37:13") == {:ok, "2024-04-08 19:37:13"}
    assert from_string("invalid") == :error
  end

  test "raw reading preserves the loose date shape and arbitrary field bytes" do
    assert read("abcd/ef/gh ij-kl-mn") == {:ok, {"abcd/ef/gh", "ij-kl-mn"}}
    assert read_fields("abcd/ef/gh ij-kl-mn") == :error

    value = <<255, 254, 253, 252>> <> "-00-99 25:60:ab"
    assert read(value) == {:ok, {<<255, 254, 253, 252>> <> "-00-99", "25:60:ab"}}

    assert read_fields(value) ==
             {:ok,
              %{
                year: <<255, 254, 253, 252>>,
                month: "00",
                day: "99",
                hour: "25",
                minute: "60",
                second: "ab",
              }}

    assert from_string(value) == :error
  end

  test "readers reject wrong lengths, missing space and non-binaries" do
    for value <- [nil, 123, [], false, "", "2024-01-02T03:04:05", "2024-01-02 03:04:05Z"] do
      assert read(value) == :error
      assert read_fields(value) == :error
      assert from_string(value) == :error
      assert parse_seconds(value) == :error
      assert_raise ArgumentError, "not a timestamp", fn -> to_seconds(value) end
    end

    for value <- ["2024-02-30 03:04:05", "2024-01-02 03-04:05"] do
      assert from_string(value) == :error
      assert parse_seconds(value) == :error
      assert_raise ArgumentError, "not a timestamp", fn -> to_seconds(value) end
    end

    assert read_fields("2024-01-02 03-04:05") == :error
  end

  test "shared shifting keeps inclusive bounds and does not wrap huge deltas" do
    assert shift("0000-01-01 00:00:00", 0) == "0000-01-01 00:00:00"
    assert shift("0000-01-01 00:00:00", -1) == nil
    assert shift("9999-12-31 23:59:59", 0) == "9999-12-31 23:59:59"
    assert shift("9999-12-31 23:59:59", 1) == nil
    assert shift("2024-02-28 23:59:59", 1) == "2024-02-29 00:00:00"
    assert shift("2024-03-01 00:00:00", -1) == "2024-02-29 23:59:59"
    span = to_seconds("9999-12-31 23:59:59") - to_seconds("0000-01-01 00:00:00")
    assert shift("0000-01-01 00:00:00", span) == "9999-12-31 23:59:59"
    assert shift("9999-12-31 23:59:59", -span) == "0000-01-01 00:00:00"

    for delta <- [9_223_372_036_854_775_808, -9_223_372_036_854_775_809, nil, 1.0, "1"] do
      assert shift("2024-01-02 03:04:05", delta) == nil
    end

    for value <- [nil, 123, "2024-02-30 00:00:00", "2024-01-02 03:04:05+00:00"] do
      assert shift(value, 1) == nil
    end
  end

  test "canonical UTC timestamps round trip, including leap days and year boundaries" do
    for string <- [
          "0000-01-01 00:00:00",
          "1970-01-01 00:00:00",
          "2024-02-29 23:59:59",
          "9999-12-31 23:59:59",
        ] do
      assert from_string(string) == {:ok, string}
      assert from_seconds(to_seconds(string)) == string
    end

    assert to_seconds("1970-01-01 00:00:00") == 0
  end

  test "every numeric offset is rejected, including zero, with either separator" do
    offsets = ~w[+02:00 -05:30 +0200 -0500 +02 -05 +00:00 -00:00 +0000 -0000 +00 -00 +24:00 +2]

    for separator <- [" ", "T"], offset <- offsets do
      assert_invalid("2020-01-01" <> separator <> "19:35:00" <> offset)
    end
  end

  test "other formats, invalid calendar fields and nonstrings are rejected" do
    for value <- [
          "2024-04-08T19:35:44",
          "2024-04-08 19:35:44Z",
          "2024-04-08T19:35:44Z",
          "2024-04-08 19:35:44.747035",
          "2024-04-08T19:35:44.747035Z",
          "2024-04-08 19:35:44.1+02:00",
          "2024-04-08",
          "20240408T193544Z",
          "2024-W15-1",
          "2024-099",
          "2024-02-30 00:00:00",
          "2023-02-29 00:00:00",
          "2024-13-01 00:00:00",
          "2024-01-01 24:00:00",
          "2024-01-01 00:60:00",
          "2024-01-01 00:00:60",
          "-0001-01-01 00:00:00",
          "10000-01-01 00:00:00",
          " 2024-04-08 19:35:44",
          "2024-04-08 19:35:44 ",
          "2024-04-08 19:35:44\n",
          "2024-04-08 19:35:44junk",
          "2024/04/08 19:35:44",
          "xxxx-04-08 19:35:44",
          <<0xFF, 0xFE>>,
          "",
          nil,
          0,
          [],
        ] do
      assert_invalid(value)
    end
  end

  defp assert_invalid(value) do
    assert from_string(value) == :error, inspect(value)
    assert parse_seconds(value) == :error, inspect(value)
    assert_raise ArgumentError, fn -> to_seconds(value) end
  end
end
