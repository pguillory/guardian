defmodule Query.Function.Trim do
  def eval(value) when is_binary(value) do
    String.trim(value)
  end

  def eval(_) do
    nil
  end
end
