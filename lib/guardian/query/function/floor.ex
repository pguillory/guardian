defmodule Guardian.Query.Function.Floor do
  # A result outside int64 is null (checked after rounding: 9.223372036854775807e18
  # rounds to 2^63).
  def eval(value) when is_integer(value) do
    value
  end

  def eval(value) when is_float(value) do
    Guardian.Query.Numeric.int64_or_nil(floor(value))
  end

  def eval(_) do
    nil
  end
end
