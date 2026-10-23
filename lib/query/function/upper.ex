defmodule Query.Function.Upper do
  def eval(value) when is_binary(value) do
    String.upcase(value)
  end

  def eval(_) do
    nil
  end
end
