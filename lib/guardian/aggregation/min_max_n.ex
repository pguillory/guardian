defmodule Guardian.Aggregation.MinMaxN do
  # min_n and max_n: the n least or greatest values, best first. The accumulator is
  # {values, n}. Null values are skipped, as in min and max.
  alias Guardian.Aggregation.Ordering

  def default(_extreme) do
    nil
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
