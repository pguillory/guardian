defmodule Guardian.Query.Function.Ltrim do
  def eval(value) when is_binary(value) do
    String.trim_leading(value)
  end

  def eval(_) do
    nil
  end
end
