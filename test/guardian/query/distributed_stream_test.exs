# The first test is vendored from distributed_stream 0.1.4 with
# lib/guardian/query/distributed_stream.ex.
defmodule Guardian.Query.DistributedStreamTest do
  import Guardian.Query.DistributedStream
  use ExUnit.Case, async: true

  test "fan_out, transform, fan_in" do
    output =
      [1, 2, 3, 4, 5]
      |> fan_out()
      |> transform(fn stream ->
        stream
        |> Stream.map(fn x -> x * 2 end)
        |> Stream.map(fn x -> x + 10 end)
      end)
      |> fan_in()
      |> Enum.sort()

    assert output == [12, 14, 16, 18, 20]
  end

  test "fan_out/1 sends each value to a random partition" do
    tagged = 1..1000 |> fan_out() |> map(&{&1, self()}) |> fan_in() |> Enum.to_list()
    assert tagged |> Enum.map(&elem(&1, 0)) |> Enum.sort() == Enum.to_list(1..1000)

    num_workers = tagged |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length()
    num_partitions = length(partitions())
    assert num_workers <= num_partitions
    if num_partitions > 1, do: assert(num_workers > 1)
  end
end
