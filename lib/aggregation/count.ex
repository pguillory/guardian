defmodule Guardian.Aggregation.Count do
  def default do
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
