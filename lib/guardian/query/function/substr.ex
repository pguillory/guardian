defmodule Guardian.Query.Function.Substr do
  def eval(value, start) when is_binary(value) and is_integer(start) and start >= 1 do
    String.slice(value, start - 1, byte_size(value))
  end

  def eval(_, _) do
    nil
  end

  def eval(value, start, count)
      when is_binary(value) and is_integer(start) and start >= 1 and is_integer(count) and
             count >= 0 do
    String.slice(value, start - 1, count)
  end

  def eval(_, _, _) do
    nil
  end
end
