defmodule ConsoleTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  # Cells are measured with the text they print: null for nil, false as false, and
  # lists as [a, b], including in a column narrower than "null".
  test "pads cells by their printed text" do
    rows = [[nil, false, [1, nil]], [1, true, []]]

    lines =
      capture_io(fn -> Console.inspect_table(["a", "b", "c"], rows) end)
      |> String.replace(~r/\e\[[0-9;]*m/, "")
      |> String.split("\n", trim: true)

    assert lines == [
             "┌──────┬───────┬───────────┐",
             "│ a    │ b     │ c         │",
             "├──────┼───────┼───────────┤",
             "│ null │ false │ [1, null] │",
             "│ 1    │ true  │ []        │",
             "└──────┴───────┴───────────┘",
           ]
  end

  test "a query that fails raises Query.Error" do
    assert_raise Query.Error, "max_n: n must be a non-negative integer", fn ->
      Console.query("select max_n(1, -1)")
    end
  end
end
