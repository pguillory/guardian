defmodule Guardian.Query.Function.Length do
  def eval(value) when is_binary(value) do
    String.length(value)
  end

  def eval(_) do
    nil
  end
end
