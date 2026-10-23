defmodule Query.Function.Abs do
  # abs(-2^63) wraps to -2^63, as negation does (Query.Numeric).
  def eval(value) when is_integer(value), do: Query.Numeric.wrap(abs(value))
  def eval(value) when is_float(value), do: abs(value)
  def eval(_), do: nil
end
