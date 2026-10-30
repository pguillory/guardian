defmodule Guardian.Test.SegmentsTest do
  use ExUnit.Case, async: true
  import Guardian.Test.Segments, only: [intercept_append: 2]
  alias Guardian.Storage.MutableSegments
  alias Guardian.Storage.Segment

  defp unique_table do
    "test_segments_#{System.unique_integer([:positive])}"
  end

  # Starts an append to `table` in a task; its callback reports and waits to be released.
  defp held_append(table) do
    test = self()

    intercept_append(table, fn from, _row ->
      send(test, {:callback, self()})

      receive do
        :release -> GenServer.reply(from, :ok)
        {:exit, reason} -> exit(reason)
      end
    end)

    [fake] = MutableSegments.get_mutable_segments(table)
    assert Segment.schema(fake, 1_000) == {:ok, %{}}
    assert Guardian.Storage.schema(table) == %{}

    task =
      Task.Supervisor.async_nolink(
        Guardian.Test.SegmentsTest.Tasks,
        fn -> Guardian.Storage.append_flattened_result(table, %{"a" => 1}) end
      )

    assert_receive {:callback, callback}
    {fake, callback, task}
  end

  setup do
    start_supervised!({Task.Supervisor, name: Guardian.Test.SegmentsTest.Tasks})
    :ok
  end

  test "the fake answers a schema read before the append and during a held callback" do
    table = unique_table()
    {fake, callback, task} = held_append(table)

    # Unregistered by now, but a read that listed it earlier still reaches it.
    assert MutableSegments.get_mutable_segments(table) == []
    assert Segment.schema(fake, 1_000) == {:ok, %{}}

    ref = Process.monitor(fake)
    send(callback, :release)
    assert Task.await(task) == :ok
    assert_receive {:DOWN, ^ref, :process, ^fake, :normal}
  end

  test "a scripted refusal reaches the caller, and the row isn't retried" do
    table = unique_table()
    intercept_append(table, fn from, _row -> GenServer.reply(from, {:error, :invalid_value}) end)

    assert Guardian.Storage.append_flattened_result(table, %{"a" => 1}) ==
             {:error, :invalid_value}

    assert Guardian.Storage.segment_ids(table) |> Enum.to_list() == []
  end

  @tag :capture_log
  test "the append's caller sees the callback's exit reason" do
    {_fake, callback, task} = held_append(unique_table())

    send(callback, {:exit, :held_append_failure})

    assert {:exit, {:held_append_failure, {GenServer, :call, _}}} =
             Task.yield(task, 5_000) || Task.shutdown(task)
  end

  test "killing the fake ends a held callback" do
    {fake, callback, task} = held_append(unique_table())
    ref = Process.monitor(callback)

    Process.exit(fake, :kill)

    # The reason can be :noproc: the kill reaches the callback through the fake, which
    # the VM doesn't order against this process's own monitor signal.
    assert_receive {:DOWN, ^ref, :process, ^callback, reason}
    assert reason in [:killed, :noproc]
    # Storage retries a row whose segment died, on a real segment.
    assert Task.await(task) == :ok
  end
end
