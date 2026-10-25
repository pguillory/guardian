defmodule Guardian.Aggregation.CountDistinct do
  def default do
    0
  end

  # Null is not a value, as in standard SQL's COUNT(DISTINCT x).
  def start(nil) do
    Hypex.new(14)
  end

  def start(value) do
    sketch = Hypex.new(14)
    Hypex.update(sketch, value)
  end

  def merge(sketch1, sketch2) do
    Hypex.merge(sketch1, sketch2)
  end

  def finish(sketch) do
    Hypex.cardinality(sketch) |> round()
  end
end
