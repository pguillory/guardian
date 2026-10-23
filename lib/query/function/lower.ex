defmodule Query.Function.Lower do
  def eval(value) when is_binary(value) do
    String.downcase(value)
  end

  def eval(_) do
    nil
  end
end
