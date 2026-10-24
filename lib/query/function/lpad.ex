defmodule Query.Function.Lpad do
  # size counts graphemes; padding adds one-byte spaces to what is already there. A
  # string that needs no padding comes back as it is. The result is the first 64 KiB
  # of the padded string (Query.Text), and no more padding than fits is built.
  def eval(value, size) when is_binary(value) and is_integer(size) do
    case size - String.length(value) do
      padding when padding > 0 ->
        max = Query.Text.max_bytes()
        spaces = String.duplicate(" ", min(padding, max))
        {head, _} = Query.Text.truncate(value, max - byte_size(spaces))
        spaces <> head

      _ ->
        value
    end
  end

  def eval(_, _) do
    nil
  end
end
