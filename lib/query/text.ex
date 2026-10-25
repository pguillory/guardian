defmodule Guardian.Query.Text do
  @moduledoc """
  Strings that query functions build: the string cap, UTF-8-safe truncation, and the
  string form of any value.

  - The cap (`max_bytes/0`, 64 KiB) bounds every string a function can build longer
    than its inputs (`concat`, `||`, `lpad`, `rpad`, `replace`, `to_string`,
    `lower`, `upper`, `normalize`, `format_timestamp`). A longer result is cut to the
    cap, never an error; `replace`, `lower`, `upper` and `normalize` cut even a value
    they don't lengthen. Functions stop building at the cap where they can rather
    than build and cut. Functions that return an input or part of one unchanged
    (`to_string` of a string, `substr`, `if`) are not capped: their result is never
    longer than a value already stored.
  - Truncation (`truncate/2`) cuts at the byte limit, less any UTF-8 character the
    limit splits (at most three bytes), so valid UTF-8 stays valid; invalid bytes
    elsewhere don't move the cut. It copies the result, so a cut string never keeps a
    larger original alive.
  - The string form (`form/2`) of a string is itself; of an integer, its decimal; of
    a float, its shortest round-trip form (`1.5`, `1.0e300`); of a boolean, `true` or
    `false`; of a list, compact JSON-style text (`[1,null,"a",[2.5]]`), its strings
    quoted and escaped as JSON, with invalid UTF-8 bytes as U+FFFD. Null has no form
    at the top level (callers decide: `to_string` gives null, `concat` an empty
    string) and is `null` inside a list.
  """

  @max_bytes 64 * 1024

  @doc "The string cap in bytes."
  def max_bytes, do: @max_bytes

  @doc """
  Cuts `string` to at most `max_bytes` bytes without splitting a UTF-8 character.
  Returns `{string, truncated?}`. Only the bytes at the limit are read: a character
  split there is dropped (up to three bytes), and invalid UTF-8 is cut the same way.

  The result is always a fresh copy, never a sub-binary, so a queued or stored row
  does not keep a larger original (a huge request body, say) alive in memory.
  """
  def truncate(string, max_bytes) when byte_size(string) <= max_bytes do
    {:binary.copy(string), false}
  end

  def truncate(string, max_bytes) do
    prefix = binary_part(string, 0, max_bytes)
    {:binary.copy(binary_part(prefix, 0, max_bytes - split_tail(prefix))), true}
  end

  # The number of bytes at the end of `prefix` that start a UTF-8 character the cut
  # split: its lead byte and the continuation bytes after it, at most three. Only the
  # last bytes are read, so invalid UTF-8 earlier in the prefix changes nothing.
  defp split_tail(prefix) do
    size = byte_size(prefix)

    Enum.find_value(1..min(3, size)//1, 0, fn back ->
      byte = :binary.at(prefix, size - back)

      cond do
        # A continuation byte: its lead byte is further back.
        byte in 0x80..0xBF -> nil
        byte in 0xC0..0xDF and back < 2 -> back
        byte in 0xE0..0xEF and back < 3 -> back
        byte in 0xF0..0xF7 and back < 4 -> back
        true -> 0
      end
    end)
  end

  @doc """
  `string` cut to the cap. A string within it is returned as it is (no copy), so
  this is free for the common case.
  """
  def cap(string) when byte_size(string) <= @max_bytes, do: string

  def cap(string) do
    {string, true} = truncate(string, @max_bytes)
    string
  end

  @doc """
  The string form of `value`, cut to at most `budget` bytes; nil for nil. Rendering
  stops once the budget is reached, so a huge list costs no more than the budget.
  """
  def form(nil, _budget), do: nil

  def form(value, budget) do
    {string, _cut?} = form_cut(value, budget)
    string
  end

  @doc """
  `{form, cut?}`: the string form of a non-nil `value` within `budget` bytes, and
  whether it was cut to fit. Code that joins forms stops at the first cut one, so
  bytes a cut freed (a split character dropped) never take a later piece.
  """
  def form_cut(value, budget) when is_binary(value) and byte_size(value) <= budget,
    do: {value, false}

  def form_cut(value, budget) when is_binary(value), do: truncate(value, budget)
  # Every other value's form has at least one byte.
  def form_cut(_value, budget) when budget <= 0, do: {"", true}

  def form_cut(value, budget) do
    # Rendering emits whole tokens and stops once past the budget, so a form that
    # doesn't fit always renders longer than the budget.
    {iodata, _left} = render(value, budget, false)
    iodata |> IO.iodata_to_binary() |> truncate(budget)
  end

  # Returns {iodata, budget left}; stops (renders nothing more) once none is left.
  defp render(_value, budget, _quoted?) when budget <= 0, do: {[], budget}
  defp render(nil, budget, _quoted?), do: emit("null", budget)
  defp render(true, budget, _quoted?), do: emit("true", budget)
  defp render(false, budget, _quoted?), do: emit("false", budget)

  defp render(value, budget, _quoted?) when is_integer(value),
    do: emit(Integer.to_string(value), budget)

  defp render(value, budget, _quoted?) when is_float(value),
    do: emit(Float.to_string(value), budget)

  # A string is rendered one byte past the budget, so a character the budget splits
  # is seen as split and dropped by the final truncate/2.
  defp render(value, budget, false) when is_binary(value) do
    emit(binary_part(value, 0, min(byte_size(value), budget + 1)), budget)
  end

  defp render(value, budget, true) when is_binary(value) do
    # A prefix one byte past the budget is enough: escaping only lengthens it.
    prefix = binary_part(value, 0, min(byte_size(value), budget + 1))
    emit([?", escape(String.replace_invalid(prefix)), ?"], budget)
  end

  defp render(list, budget, _quoted?) when is_list(list) do
    {open, budget} = emit("[", budget)
    {items, budget} = render_items(list, budget, [])
    {close, budget} = emit("]", budget)
    {[open, items, close], budget}
  end

  # Not a storable value (a map, say): nothing a query can produce, but no raise.
  defp render(_value, budget, _quoted?), do: {[], budget}

  defp render_items([], budget, acc), do: {Enum.reverse(acc), budget}
  defp render_items(_items, budget, acc) when budget <= 0, do: {Enum.reverse(acc), budget}

  defp render_items([item | items], budget, acc) do
    {separator, budget} = if acc == [], do: {[], budget}, else: emit(",", budget)
    {rendered, budget} = render(item, budget, true)
    render_items(items, budget, [rendered, separator | acc])
  end

  defp emit(iodata, budget), do: {iodata, budget - IO.iodata_length(iodata)}

  defp escape(string) do
    for <<char::utf8 <- string>>, into: "" do
      case char do
        ?" -> "\\\""
        ?\\ -> "\\\\"
        ?\n -> "\\n"
        ?\r -> "\\r"
        ?\t -> "\\t"
        ?\b -> "\\b"
        ?\f -> "\\f"
        c when c < 0x20 -> "\\u" <> String.pad_leading(Integer.to_string(c, 16), 4, "0")
        c -> <<c::utf8>>
      end
    end
  end
end
