defmodule Guardian.Query.Function.Reverse do
  def eval(value) when is_binary(value) do
    String.reverse(value)
  end

  def eval(_) do
    nil
  end
end
