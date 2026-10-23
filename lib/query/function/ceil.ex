defmodule Query.Function.Ceil do
  def eval(value) when is_number(value) do
    ceil(value)
  end

  def eval(_) do
    nil
  end
end
