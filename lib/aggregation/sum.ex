defmodule Guardian.Aggregation.Sum do
  def default do
    0.0
  end

  def start(value) when is_number(value) do
    value
  end

  def start(_value) do
    nil
  end

  def merge(nil, nil) do
    nil
  end

  def merge(value1, nil) do
    value1
  end

  def merge(nil, value2) do
    value2
  end

  # Integers wrap to int64 like `+`. A float overflow makes the sum :overflow, which
  # absorbs every later merge and finishes as null (Guardian.Query.Numeric): an overflowed
  # partial sum must not look like an empty one.
  def merge(:overflow, _value2), do: :overflow
  def merge(_value1, :overflow), do: :overflow

  def merge(value1, value2) when is_integer(value1) and is_integer(value2) do
    Guardian.Query.Numeric.wrap(value1 + value2)
  end

  def merge(value1, value2) do
    value1 + value2
  catch
    :error, :badarith -> :overflow
  end

  def finish(:overflow), do: nil

  def finish(value) do
    value
  end
end
