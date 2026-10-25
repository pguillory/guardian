defmodule Guardian.Aggregation.Arbitrary do
  # The state is the value of some row, which can itself be null. :empty (not a
  # storable value) is the state of no rows, so a real null is kept as a value.

  def empty do
    :empty
  end

  def start(value) do
    value
  end

  def merge(:empty, value2) do
    value2
  end

  def merge(value1, _value2) do
    value1
  end

  def finish(:empty) do
    nil
  end

  def finish(value) do
    value
  end
end
