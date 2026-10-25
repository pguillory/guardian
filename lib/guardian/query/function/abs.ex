defmodule Guardian.Query.Function.Abs do
  # abs(-2^63) wraps to -2^63, as negation does (Guardian.Query.Numeric).
  def eval(value) when is_integer(value) do
    Guardian.Query.Numeric.wrap(abs(value))
  end

  def eval(value) when is_float(value) do
    abs(value)
  end

  def eval(_) do
    nil
  end
end
