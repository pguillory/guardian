defmodule Query.Function.Round do
  # A result outside int64 is null (checked after rounding: 9.223372036854775807e18
  # rounds to 2^63).
  def eval(value) when is_integer(value), do: value
  def eval(value) when is_float(value), do: Query.Numeric.int64_or_nil(round(value))
  def eval(_), do: nil
end
