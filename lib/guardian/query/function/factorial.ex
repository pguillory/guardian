defmodule Guardian.Query.Function.Factorial do
  # Above factorial(20) the result doesn't fit in int64: null.
  def eval(value) when is_integer(value) and value >= 0 and value <= 20 do
    Enum.reduce(1..value//1, 1, &*/2)
  end

  def eval(_) do
    nil
  end
end
