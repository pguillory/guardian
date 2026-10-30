defmodule Guardian.Query.WorkerErrorsTest do
  use ExUnit.Case, async: true
  import Guardian.Query.WorkerErrors

  defp dead_collector do
    {pid, ref} = spawn_monitor(fn -> :ok end)

    receive do
      {:DOWN, ^ref, :process, ^pid, :normal} -> :ok
    end

    pid
  end

  test "the first reported error is returned, and later guarded work is skipped" do
    collector = start()
    assert guard(collector, fn -> [1, 2] end) == [1, 2]
    assert first(collector) == nil

    assert guard(collector, fn -> raise "first" end) == []
    assert guard(collector, fn -> raise "never run" end) == []
    assert %Guardian.Query.Error{message: message} = first(collector)
    assert message =~ "first"
  end

  test "a collector that is gone fails the query rather than reading as no error" do
    collector = dead_collector()
    assert guard(collector, fn -> raise "lost" end) == []
    assert %Guardian.Query.Error{message: message} = first(collector)
    assert message =~ "collector stopped"
  end
end
