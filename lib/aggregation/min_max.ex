defmodule Aggregation.MinMax do
  # min and max. Null values are skipped.

  def default(_extreme) do
    nil
  end

  def start(_extreme, value) do
    value
  end

  def merge(_extreme, nil, value2) do
    value2
  end

  def merge(_extreme, value1, nil) do
    value1
  end

  def merge(extreme, value1, value2) do
    if Aggregation.Ordering.wins?(extreme, value1, value2), do: value1, else: value2
  end

  def finish(_extreme, value) do
    value
  end
end
