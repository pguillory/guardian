defmodule Query.Function.Div do
  # Division by zero is null; div(-2^63, -1) wraps (Query.Numeric).
  def eval(value1, value2) when is_integer(value1) and is_integer(value2) and value2 != 0 do
    Query.Numeric.wrap(div(value1, value2))
  end

  def eval(_, _) do
    nil
  end
end
