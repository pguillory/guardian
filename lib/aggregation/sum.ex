defmodule Aggregation.Sum do
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

  def merge(value1, value2) do
    value1 + value2
  end

  def finish(value) do
    value
  end
end
