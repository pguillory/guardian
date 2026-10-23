defmodule Query.Function.Div do
  def eval(value1, value2) when is_integer(value1) and is_integer(value2) do
    div(value1, value2)
  end

  def eval(_, _) do
    nil
  end
end
