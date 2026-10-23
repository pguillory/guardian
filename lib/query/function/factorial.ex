defmodule Query.Function.Factorial do
  def eval(value) when is_integer(value) and value >= 0 do
    Query.Limits.check_factorial!(value)
    Enum.reduce(1..value//1, 1, &*/2)
  end

  def eval(_) do
    nil
  end
end
