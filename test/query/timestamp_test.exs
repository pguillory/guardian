defmodule Query.TimestampTest do
  use Query.EvaluationTestCase, async: true

  @timestamp "2024-01-02 03:04:05"
  @offsets ~w[+02:00 -05:30 +0200 -0500 +02 -05 +00:00 -00:00 +0000 -0000 +00 -00]
  @rejected (for separator <- [" ", "T"], offset <- @offsets do
               "2024-01-02" <> separator <> "03:04:05" <> offset
             end) ++
              [
                "2024-01-02T03:04:05",
                "2024-01-02T03:04:05Z",
                "2024-01-02 03:04:05Z",
                "2024-01-02 03:04:05.9",
                "2024-01-02T03:04:05.9Z",
                "2024-01-02 03:04:05.9-01:00",
                "2024-01-02 03:04:05 ",
                "2024-01-02",
                "not a time",
              ]

  @operations [
    {"date_add(value, delta)", "2024-01-02 03:04:10"},
    {"adddate(value, delta)", "2024-01-02 03:04:10"},
    {"date_sub(value, delta)", "2024-01-02 03:04:00"},
    {"subdate(value, delta)", "2024-01-02 03:04:00"},
    {"value + delta", "2024-01-02 03:04:10"},
    {"delta + value", "2024-01-02 03:04:10"},
    {"value - delta", "2024-01-02 03:04:00"},
    {"to_seconds(value)", 1_704_164_645},
    {"unix_timestamp(value)", 1_704_164_645},
    {"date(value)", "2024-01-02"},
    {"format_timestamp(value, 'yyyy-MM-dd hh:mm:ss')", @timestamp},
  ]

  test "time functions and arithmetic accept only the UTC format, for literals and rows" do
    for {expression, expected} <- @operations,
        timestamp <- [@timestamp | @rejected] do
      expected = if timestamp == @timestamp, do: expected, else: nil

      literal =
        expression |> String.replace("value", "'#{timestamp}'") |> String.replace("delta", "5")

      assert eval(literal) == expected, literal
      assert eval(expression, value: timestamp, delta: 5) == expected, expression
    end
  end

  test "mixed timestamp columns agree with per-row time evaluation" do
    rows = Enum.map([@timestamp | @rejected], &%{value: &1, delta: 5})

    for {expression, result} <- @operations do
      expected = [result | List.duplicate(nil, length(@rejected))]
      assert eval_segment_and_rows(expression, rows) == {expected, expected}, expression
    end
  end

  test "mixed timestamp, integer and null columns preserve arithmetic dispatch" do
    rows = Enum.map([@timestamp, @timestamp <> "+02:00", 7, nil], &%{value: &1, delta: 5})

    for {expression, expected} <- [
          {"value + delta", ["2024-01-02 03:04:10", nil, 12, nil]},
          {"delta + value", ["2024-01-02 03:04:10", nil, 12, nil]},
          {"value - delta", ["2024-01-02 03:04:00", nil, 2, nil]},
          {"delta - value", [nil, nil, -2, nil]},
        ] do
      assert eval_segment_and_rows(expression, rows) == {expected, expected}, expression
    end
  end
end
