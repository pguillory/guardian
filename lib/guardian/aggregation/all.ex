defmodule Guardian.Aggregation.All do
  def default do
    true
  end

  def start(true) do
    true
  end

  def start(false) do
    false
  end

  def start(_) do
    nil
  end

  def merge(true, true) do
    true
  end

  def merge(_, false) do
    false
  end

  def merge(false, _) do
    false
  end

  def merge(_, _) do
    nil
  end

  def finish(acc) do
    acc
  end
end
