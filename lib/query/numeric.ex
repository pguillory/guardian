defmodule Query.Numeric do
  @moduledoc """
  The number rules every function, operator and aggregate follows (the maintainer's decision:
  "null means there's no good value").

  - Integers are 64-bit and wrap on overflow, two's complement, exactly as the column
    NIF's arithmetic does (`wrap/1`). A wrapped result is wrong but never a crash,
    and keeps both evaluation paths in agreement.
  - A float result that isn't finite is null. Erlang raises on float overflow rather
    than producing infinity, so float arithmetic catches that raise
    (`:error, :badarith`) and returns null; the NIF stores a non-finite result as
    null.
  - A result with no good value (a square root of a negative, division by zero, a
    rounded float outside int64) is null.
  """

  import Bitwise

  @min -0x8000000000000000
  @max 0x7FFFFFFFFFFFFFFF

  def min_int, do: @min
  def max_int, do: @max

  @doc "Whether `value` is an integer within int64."
  defguard int64?(value) when is_integer(value) and value >= @min and value <= @max

  @doc "`value` wrapped into int64, two's complement."
  def wrap(value) when int64?(value), do: value

  def wrap(value) when is_integer(value) do
    low = band(value, 0xFFFFFFFFFFFFFFFF)
    if low > @max, do: low - 0x10000000000000000, else: low
  end

  @doc "`value` if it is an integer within int64, else null."
  def int64_or_nil(value) when int64?(value), do: value
  def int64_or_nil(_value), do: nil
end
