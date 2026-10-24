defmodule Aggregation.MinMaxN do
  # min_n and max_n: the n least or greatest values, best first. The accumulator is
  # {values, n}. Null values are skipped, as in min and max.
  alias Aggregation.Ordering

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

  # A list of list-of-lists values nests deeper than storage holds
  # (Storage.Value.valid?/1), so it is null, as Query.ColumnOrConstant makes any such
  # expression value.
  def finish(_extreme, {values, _n}) do
    if Storage.Value.valid?(values), do: values, else: nil
  end

  defp name(:min), do: "min_n"
  defp name(:max), do: "max_n"
end
