defmodule Guardian.Aggregation.MinMaxBy do
  # min_by and max_by: the value of the row with the least or greatest ordering value.
  # Rows whose ordering value is null are skipped.

  # nil is the state of no row; a row's state is a tuple, even when its value is null.
  def empty(_extreme) do
    nil
  end

  def start(_extreme, _value, nil) do
    nil
  end

  def start(_extreme, value, order_value) do
    {value, order_value}
  end

  def merge(_extreme, nil, acc2) do
    acc2
  end

  def merge(_extreme, acc1, nil) do
    acc1
  end

  def merge(extreme, {_, order_value1} = acc1, {_, order_value2} = acc2) do
    if Guardian.Aggregation.Ordering.wins?(extreme, order_value1, order_value2),
      do: acc1,
      else: acc2
  end

  def finish(_extreme, nil) do
    nil
  end

  def finish(_extreme, {value, _order_value}) do
    value
  end
end
