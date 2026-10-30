defmodule Guardian.Storage.PersistedSegmentsSchedulingTest do
  # Not async: suspends the node-wide PersistedSegments server.
  use ExUnit.Case, async: false

  alias Guardian.Storage.FullSegments
  alias Guardian.Storage.PersistedSegments
  alias Guardian.Storage.Segment

  test "external pings leave only one recurring periodic timer" do
    on_exit(fn -> :ok = :sys.resume(PersistedSegments) end)

    for _ <- 1..20, do: PersistedSegments.ping()
    :sys.get_state(PersistedSegments)

    for _ <- 1..2 do
      :ok = :sys.suspend(PersistedSegments)
      # A suspended server cannot consume or reschedule a tick. Every active
      # timer chain therefore contributes exactly one queued message.
      Process.sleep(1100)
      {:messages, messages} = Process.info(Process.whereis(PersistedSegments), :messages)
      assert Enum.count(messages, &(&1 == :ping)) == 1
      :ok = :sys.resume(PersistedSegments)
      :sys.get_state(PersistedSegments)
    end
  end

  test "external pings persist pending segments before replying to a barrier" do
    {id, segment, filename} = pending_segment()

    :ok = PersistedSegments.ping()
    :sys.get_state(PersistedSegments)

    assert_persisted(id, segment, filename)
  end

  test "periodic persistence processes new work across successive ticks without casts" do
    for _ <- 1..2 do
      {id, segment, filename} = pending_segment()
      await_persisted(id, System.monotonic_time(:millisecond) + 3000)
      # The destination becomes visible before Full is unregistered. Wait for
      # the periodic callback to finish before checking the completed handoff.
      :sys.get_state(PersistedSegments)
      assert_persisted(id, segment, filename)
    end
  end

  defp pending_segment do
    table = "persistence_timer_#{System.unique_integer([:positive])}"
    id = Guardian.SegmentID.generate()
    {:ok, segment} = Segment.start_link(capacity: 1)
    Process.unlink(segment)
    filename = Guardian.Storage.SegmentFile.filename(table, id)

    on_exit(fn ->
      :ok = :sys.resume(PersistedSegments)

      # Remove only this fixture's registration and links before stopping it.
      for registry <- [FullSegments, PersistedSegments] do
        :sys.replace_state(registry, fn state ->
          Process.unlink(segment)
          {:reply, :ok, next} = registry.handle_call({:delete_segment, id}, nil, state)
          next
        end)
      end

      :ok = Guardian.Storage.LoadedSegments.delete_segment(id)
      File.rm(filename)
      :ok = Segment.retire(segment)
    end)

    assert {:ok, :full} = Segment.append(segment, %{"a" => 1})
    :ok = Segment.freeze(segment)
    # Register full work directly so no MutableSegments rollover cast can hide
    # a missing periodic timer.
    :ok = FullSegments.insert({id, segment, table})
    {id, segment, filename}
  end

  defp assert_persisted(id, segment, filename) do
    assert FullSegments.get_segment(id) == {:error, :not_found}
    assert PersistedSegments.get_segment(id) == {:ok, segment}
    assert File.exists?(filename)
    {:ok, loaded} = Segment.start_link(load: filename)
    assert Segment.count(loaded) == {:ok, 1}
    assert Guardian.Test.Segments.segment_row(loaded, 0) == {:ok, %{"a" => 1}}
    :ok = Segment.retire(loaded)
  end

  defp await_persisted(id, deadline) do
    case PersistedSegments.get_segment(id) do
      {:ok, _segment} ->
        :ok

      {:error, :not_found} ->
        assert System.monotonic_time(:millisecond) < deadline,
               "periodic persistence did not process the pending segment"

        Process.sleep(10)
        await_persisted(id, deadline)
    end
  end
end
