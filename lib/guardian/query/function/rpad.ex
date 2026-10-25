defmodule Guardian.Query.Function.Rpad do
  # size counts graphemes; padding adds one-byte spaces to what is already there. A
  # string that needs no padding comes back as it is. The result is the first 64 KiB
  # of the padded string (Guardian.Query.Text), and no more padding than fits is built.
  def eval(value, size) when is_binary(value) and is_integer(size) do
    case size - String.length(value) do
      padding when padding > 0 ->
        max = Guardian.Query.Text.max_bytes()

        case Guardian.Query.Text.truncate(value, max) do
          {head, true} -> head
          {value, false} -> value <> String.duplicate(" ", min(padding, max - byte_size(value)))
        end

      _ ->
        value
    end
  end

  def eval(_, _) do
    nil
  end
end
