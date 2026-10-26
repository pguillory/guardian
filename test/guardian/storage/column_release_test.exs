defmodule Guardian.Storage.ColumnReleaseTest do
  # Not async: the live-column counter is global to the VM.
  use ExUnit.Case, async: false
  import Guardian.Test.Polling, only: [eventually_after_gc: 1]

  alias Guardian.Storage.Column
  alias Guardian.Storage.Column.NIF

  @columns 1000

  # Other processes (for example a running application) may create or drop a few columns
  # while this test runs, so allow some slack. A leak shows up as all @columns.
  @slack 100

  test "a dropped column releases its native buffers" do
    before = NIF.live_columns()

    task =
      Task.async(fn ->
        columns =
          for i <- 1..@columns do
            column = Column.new(0)
            :ok = Column.append(column, "value #{i}")
            column
          end

        # Using the columns after the count keeps them referenced until then.
        {NIF.live_columns(), length(columns)}
      end)

    {during, @columns} = Task.await(task)
    assert during - before >= @columns - @slack

    # The task has exited, so nothing refers to its columns.
    eventually_after_gc(fn -> NIF.live_columns() - before < @slack end)
  end

  test "a column survives its creator while another process holds it" do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        column = Column.new(0)
        :ok = Column.append(column, "kept")
        send(parent, {:column, column})
      end)

    # Explicit timeouts: under load the spawned process can take longer than the
    # previous 100 ms default to allocate the column and exit.
    assert_receive {:column, column}, 5_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    :erlang.garbage_collect()

    assert Column.to_list(column) == ["kept"]
  end
end
