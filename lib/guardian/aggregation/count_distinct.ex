defmodule Guardian.Aggregation.CountDistinct do
  # HyperLogLog at precision 8, with fixed 256-byte bitstring registers, for queries
  # and counters alike.
  @precision 8

  def empty do
    Hypex.new(@precision, Hypex.Bitstring)
  end

  # Null is not a value, as in standard SQL's COUNT(DISTINCT x).
  def start(nil) do
    empty()
  end

  def start(value) do
    Hypex.update(empty(), value)
  end

  def merge(sketch1, sketch2) do
    Hypex.merge(sketch1, sketch2)
  end

  def finish(sketch) do
    Hypex.cardinality(sketch) |> round()
  end
end
