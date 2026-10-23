defmodule Aggregation.Arbitrary do
  def default do
    nil
  end

  def start(value) do
    value
  end

  def merge(value1, _value2) do
    value1
  end

  def finish(value) do
    value
  end
end
