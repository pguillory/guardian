defmodule Aggregation.Moments do
  # var_pop, var_samp, stddev_pop and stddev_samp; the option names which.
  #
  # The accumulator is {count, mean, m2}, where m2 is the sum of squared deviations
  # from the mean, merged with Chan et al.'s parallel update. Unlike a sum of squares,
  # m2 never goes negative and does not cancel when values are nearly equal or far
  # from zero. Values that are not numbers are skipped.

  def default(_kind) do
    nil
  end

  def start(_kind, value) when is_number(value) do
    {1, value, 0.0}
  end

  def start(_kind, _) do
    {0, 0.0, 0.0}
  end

  # A float overflow while merging makes the state :overflow, which absorbs every
  # later merge and finishes as null (Query.Numeric).
  def merge(_kind, :overflow, _acc2), do: :overflow
  def merge(_kind, _acc1, :overflow), do: :overflow

  def merge(_kind, {0, _, _}, acc2) do
    acc2
  end

  def merge(_kind, acc1, {0, _, _}) do
    acc1
  end

  def merge(_kind, {count1, mean1, m2_1}, {count2, mean2, m2_2}) do
    count = count1 + count2
    delta = mean2 - mean1
    mean = mean1 + delta * count2 / count
    m2 = m2_1 + m2_2 + delta * delta * count1 * count2 / count
    {count, mean, m2}
  catch
    :error, :badarith -> :overflow
  end

  def finish(_kind, :overflow), do: nil

  def finish(:var_pop, {count, _mean, m2}) when count > 0 do
    m2 / count
  end

  def finish(:var_samp, {count, _mean, m2}) when count > 1 do
    m2 / (count - 1)
  end

  def finish(:stddev_pop, {count, _mean, m2}) when count > 0 do
    :math.sqrt(m2 / count)
  end

  def finish(:stddev_samp, {count, _mean, m2}) when count > 1 do
    :math.sqrt(m2 / (count - 1))
  end

  def finish(_kind, _) do
    nil
  end
end
