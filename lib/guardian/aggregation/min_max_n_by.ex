defmodule Guardian.Aggregation.MinMaxNBy do
  # min_n_by and max_n_by: the values of the n rows with the least or greatest ordering
  # values, best first. The accumulator is {[{value, order_value}], n}. Rows whose
  # ordering value is null are skipped.
  alias Guardian.Aggregation.Ordering

  def default(_extreme) do
    nil
  end

  def start(extreme, value, order_value, n) do
    n = Ordering.check_n!(name(extreme), n)

    if order_value == nil or n == 0 do
      {[], n}
    else
      {[{value, order_value}], n}
    end
  end

  def merge(extreme, acc1, acc2) do
    Ordering.merge_n(name(extreme), acc1, acc2, fn {_, order_value1}, {_, order_value2} ->
      Ordering.wins?(extreme, order_value1, order_value2)
    end)
  end

  def finish(_extreme, {value_orders, _n}) do
    Enum.map(value_orders, fn {value, _order_value} -> value end)
  end

  defp name(:min) do
    "min_n_by"
  end

  defp name(:max) do
    "max_n_by"
  end
end
