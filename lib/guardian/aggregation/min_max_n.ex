defmodule Guardian.Aggregation.MinMaxN do
  # min_n and max_n: the n least or greatest values, best first. The accumulator is
  # {values, n}, or :empty for no rows. Null values are skipped, as in min and max.
  alias Guardian.Aggregation.Ordering

  def empty(_extreme) do
    :empty
  end

  def start(extreme, value, n) do
    n = Ordering.check_n!(name(extreme), n)

    if value == nil or n == 0 do
      {[], n}
    else
      {[value], n}
    end
  end

  def merge(extreme, acc1, acc2) do
    Ordering.merge_n(name(extreme), acc1, acc2, &Ordering.wins?(extreme, &1, &2))
  end

  def finish(_extreme, :empty) do
    nil
  end

  def finish(_extreme, {values, _n}) do
    values
  end

  defp name(:min) do
    "min_n"
  end

  defp name(:max) do
    "max_n"
  end
end
