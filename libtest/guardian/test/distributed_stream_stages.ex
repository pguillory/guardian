defmodule Guardian.Test.DistributedStreamStages do
  @moduledoc """
  Stage functions for multi-node DistributedStream tests. Test modules are compiled in
  memory and not loaded on peer nodes, so functions that run there live here.
  """

  @doc "A fan-out function sending everything to partition 1 on `node`."
  def to(node) do
    fn _ -> {node, 1} end
  end

  @doc """
  Builds about 40 MB of heap plus its stack (1,000,000 small tuples) and returns its
  length: over the test environment's 16 MiB query heap limit, well under production's
  256 MiB.
  """
  def grow_heap(_value) do
    1..1_000_000 |> Enum.map(&{&1, &1}) |> length()
  end

  @doc "Pads each value to fill a 1,000-byte chunk on its own."
  def big(value) do
    {value, String.duplicate("x", 1_000)}
  end

  @doc """
  A transform that pads values and, just before producing value number `k` (from 0),
  drops this node's connection to `other`. The next message to `other` reconnects.
  """
  def disconnect_at(other, k) do
    fn stream ->
      stream
      |> Stream.with_index()
      |> Stream.map(fn {value, index} ->
        if index == k, do: :erlang.disconnect_node(other)
        big(value)
      end)
    end
  end

  @doc """
  A transform that pads values and drops this node's connection to `other` after the
  last value, so chunks already sent may be lost while the marker that follows (on a
  new connection) arrives.
  """
  def disconnect_at_end(other) do
    fn stream ->
      Stream.concat(
        Stream.map(stream, &big/1),
        Stream.flat_map([:end], fn :end ->
          :erlang.disconnect_node(other)
          []
        end)
      )
    end
  end
end
