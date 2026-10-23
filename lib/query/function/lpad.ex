defmodule Query.Function.Lpad do
  def eval(value, size) when is_binary(value) and is_integer(size) do
    # size counts graphemes; padding adds one-byte spaces to what is already there.
    # A string that needs no padding comes back as it is.
    padding = size - String.length(value)
    if padding > 0, do: Query.Limits.check_string_size!("lpad", byte_size(value) + padding)
    String.pad_leading(value, size)
  end

  def eval(_, _) do
    nil
  end
end
