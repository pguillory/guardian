defmodule Console do
  def exit do
    IO.puts("Exiting...")
    ref = make_ref()
    System.stop()

    receive do
      ^ref -> :never
    end
  end

  def query(source) when is_binary(source) do
    case Query.execute(source) do
      {:ok, labels, rows} -> inspect_table(labels, rows)
      {:error, message} -> raise Query.Error, message: message
    end
  end

  def lengths(labels, rows) do
    lengths = Enum.map(labels, &String.length/1)

    Enum.reduce(rows, lengths, fn row, lengths ->
      SuperList.map(row, lengths, &max(String.length(display_text(&1)), &2))
    end)
  end

  def inspect_table(labels, rows) do
    lengths = lengths(labels, rows)

    divider1 = "┌─" <> Enum.map_join(lengths, "─┬─", &String.duplicate("─", &1)) <> "─┐"
    divider2 = "├─" <> Enum.map_join(lengths, "─┼─", &String.duplicate("─", &1)) <> "─┤"
    divider3 = "└─" <> Enum.map_join(lengths, "─┴─", &String.duplicate("─", &1)) <> "─┘"

    labels = [
      "│ ",
      Enum.join(SuperList.map(labels, lengths, &String.pad_trailing/2), " │ "),
      " │",
    ]

    rows =
      Enum.map(rows, fn row ->
        ["│ ", Enum.join(SuperList.map(row, lengths, &pad_ansi/2), " │ "), " │"]
      end)

    IO.puts(divider1)
    IO.puts(labels)
    IO.puts(divider2)
    Enum.each(rows, &IO.puts/1)
    IO.puts(divider3)
  end

  # Padding is computed from `display_text/1`, the same text `ansi/1` prints, so the
  # measured width and the printed width cannot disagree.
  def pad_ansi(value, length) do
    ansi(value) <> String.duplicate(" ", length - String.length(display_text(value)))
  end

  def ansi(list) when is_list(list) do
    "[" <> Enum.map_join(list, ", ", &ansi/1) <> "]"
  end

  def ansi(value) do
    IO.ANSI.format([color(value), display_text(value)])
    |> IO.iodata_to_binary()
  end

  # The text a cell shows: `null` for nil, lists as `[a, b]`.
  defp display_text(nil), do: "null"

  defp display_text(list) when is_list(list),
    do: "[" <> Enum.map_join(list, ", ", &display_text/1) <> "]"

  defp display_text(value), do: to_string(value)

  def color(nil) do
    :light_black
  end

  def color(false) do
    :red
  end

  def color(true) do
    :green
  end

  def color(number) when is_number(number) do
    :blue
  end

  def color(string) when is_binary(string) do
    :black
  end

  def color(list) when is_list(list) do
    :black
  end
end
