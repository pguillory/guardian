# Vendored with lib/guardian/query/distributed_stream.ex; see the note at the top of that file.
defimpl Enumerable, for: Guardian.Query.DistributedStream do
  def count(_) do
    {:error, __MODULE__}
  end

  def member?(_, _) do
    {:error, __MODULE__}
  end

  def slice(_) do
    {:error, __MODULE__}
  end

  def reduce(distributed_stream, acc, fun) do
    stream = Guardian.Query.DistributedStream.fan_in(distributed_stream)
    Enumerable.reduce(stream, acc, fun)
  end
end
