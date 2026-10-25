defmodule Guardian.Aggregation.Avg do
  def default do
    nil
  end

  # Values that are not numbers (null, strings, booleans, lists) are skipped, as in
  # sum. The integer 0 keeps a sum of integers exact until finish/1 divides.
  def start(value) when is_number(value) do
    {value, 1}
  end

  def start(_value) do
    {0, 0}
  end

  # An integer sum stays exact (a bignum of a few words at most, for any real count).
  # A float overflow makes the state :overflow, which absorbs every later merge and
  # finishes as null (Guardian.Query.Numeric).
  def merge(:overflow, _acc2) do
    :overflow
  end

  def merge(_acc1, :overflow) do
    :overflow
  end

  def merge({sum1, count1}, {sum2, count2}) do
    {sum1 + sum2, count1 + count2}
  catch
    :error, :badarith -> :overflow
  end

  def finish(:overflow) do
    nil
  end

  def finish({_sum, 0}) do
    nil
  end

  def finish({sum, count}) do
    sum / count
  catch
    :error, :badarith -> nil
  end
end
