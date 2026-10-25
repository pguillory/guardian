defmodule Guardian.Query.TimestampTest do
  use Guardian.Query.EvaluationTestCase, async: true

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

  test "date extraction stays looser than formatting and calendar arithmetic" do
    values = [
      {"abcd/ef/gh ij-kl-mn", "abcd/ef/gh", nil},
      {"abcd-ef-gh ij:kl:mn", "abcd-ef-gh", "abcd-ef-gh ij:kl:mn"},
      {"2024-02-30 25:60:99", "2024-02-30", "2024-02-30 25:60:99"},
      {<<255, 254, 253, 252>> <> "-00-99 25:60:ab", <<255, 254, 253, 252>> <> "-00-99",
       <<255, 254, 253, 252>> <> "-00-99 25:60:ab"},
      {nil, nil, nil},
      {123, nil, nil},
    ]

    rows = Enum.map(values, fn {value, _, _} -> %{value: value} end)
    dates = Enum.map(values, &elem(&1, 1))
    formatted = Enum.map(values, &elem(&1, 2))
    nulls = List.duplicate(nil, length(values))

    assert eval_segment_and_rows("date(value)", rows) == {dates, dates}

    assert eval_segment_and_rows("format_timestamp(value, 'yyyy-MM-dd hh:mm:ss')", rows) ==
             {formatted, formatted}

    for expression <- ["date_add(value, 0)", "date_sub(value, 0)", "to_seconds(value)"] do
      assert eval_segment_and_rows(expression, rows) == {nulls, nulls}
    end
  end

  test "formatter keeps token-specific failures, raw fields and zero trimming" do
    assert eval("format_timestamp('0000-00-00 00:00:00', 'y|M|d|h|m|s')") == "|||||"

    assert eval("format_timestamp('abcd-13-gh 25:kl:mn', 'yyyy-MM-dd hh:mm:ss')") ==
             "abcd-13-gh 25:kl:mn"

    assert eval("format_timestamp('abcd-13-gh 25:kl:mn', '')") == ""

    for format <- ["MMM", "MMMM", "AM", "PM", "am", "pm"] do
      assert eval("format_timestamp(value, format)", value: "abcd-13-gh 25:kl:mn", format: format) ==
               nil
    end

    prefix = String.duplicate("!", 65_537)

    assert eval("format_timestamp(value, format)", value: @timestamp, format: prefix) ==
             String.duplicate("!", 65_536)

    for token <- ["MMM", "MMMM", "AM", "PM", "am", "pm"] do
      assert eval("format_timestamp(value, format)",
               value: "2024-13-01 25:00:00",
               format: prefix <> token
             ) == nil
    end
  end

  test "arithmetic aliases and both addition orders keep boundary results" do
    rows = [
      %{value: "0000-01-01 00:00:00", delta: -1},
      %{value: "9999-12-31 23:59:59", delta: 1},
      %{value: "2024-02-28 23:59:59", delta: 1},
      %{value: "2024-03-01 00:00:00", delta: -1},
      %{value: "2024-01-01 00:00:00", delta: -9_223_372_036_854_775_808},
    ]

    for expression <- [
          "date_add(value, delta)",
          "adddate(value, delta)",
          "value + delta",
          "delta + value",
        ] do
      expected = [nil, nil, "2024-02-29 00:00:00", "2024-02-29 23:59:59", nil]
      assert eval_segment_and_rows(expression, rows) == {expected, expected}
    end

    for expression <- ["date_sub(value, delta)", "subdate(value, delta)", "value - delta"] do
      expected = [
        "0000-01-01 00:00:01",
        "9999-12-31 23:59:58",
        "2024-02-28 23:59:58",
        "2024-03-01 00:00:01",
        nil,
      ]

      assert eval_segment_and_rows(expression, rows) == {expected, expected}
    end
  end
end
