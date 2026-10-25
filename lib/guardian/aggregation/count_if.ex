defmodule Guardian.Aggregation.CountIf do
  def empty do
    0
  end

  def start(true) do
    1
  end

  def start(_) do
    0
  end

  def merge(value1, value2) do
    value1 + value2
  end

  def finish(value) do
    value
  end
end
