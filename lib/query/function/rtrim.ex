defmodule Guardian.Query.Function.Rtrim do
  def eval(value) when is_binary(value) do
    String.trim_trailing(value)
  end

  def eval(_) do
    nil
  end
end
