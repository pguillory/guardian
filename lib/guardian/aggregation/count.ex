defmodule Guardian.Aggregation.Count do
  # count() and count(x). The count is returned raw: values storage cannot hold
  # (an integer outside int64) are refused where they are stored.

  def empty do
    0
  end

  def start do
    1
  end

  def start(nil) do
    0
  end

  def start(_value) do
    1
  end

  def merge(value1, value2) do
    value1 + value2
  end

  def finish(value) do
    value
  end
end
