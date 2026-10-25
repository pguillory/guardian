defmodule Guardian.Aggregation.CountDistinct do
  def default do
    0
  end

  def empty({precision, backend}) do
    Hypex.new(precision, backend)
  end

  # Null is not a value, as in standard SQL's COUNT(DISTINCT x).
  def start(value) do
    start({14, Hypex.Array}, value)
  end

  def start(configuration, nil) do
    empty(configuration)
  end

  def start(configuration, value) do
    Hypex.update(empty(configuration), value)
  end

  def merge(sketch1, sketch2) do
    Hypex.merge(sketch1, sketch2)
  end

  def merge(_configuration, sketch1, sketch2) do
    merge(sketch1, sketch2)
  end

  def finish(sketch) do
    Hypex.cardinality(sketch) |> round()
  end

  def finish(_configuration, sketch) do
    finish(sketch)
  end
end
