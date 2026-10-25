defmodule Guardian.Aggregation.Count do
  def default(_context) do
    0
  end

  def empty(_context) do
    0
  end

  def start(_context) do
    1
  end

  def start(_context, nil) do
    0
  end

  def start(_context, _value) do
    1
  end

  def merge(_context, value1, value2) do
    value1 + value2
  end

  def finish(:query, value) do
    value
  end

  def finish(:counter, value) do
    Guardian.Query.Numeric.int64_or_nil(value)
  end
end
