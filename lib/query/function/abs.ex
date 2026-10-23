defmodule Query.Function.Abs do
  def eval(value) when is_number(value) do
    abs(value)
  end

  def eval(_) do
    nil
  end
end
