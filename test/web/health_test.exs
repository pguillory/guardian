defmodule Web.HealthTest do
  # Not async: it stops and restarts a Storage child.
  use ExUnit.Case, async: false

  defp health do
    conn = Plug.Test.conn(:get, "/health") |> Web.MainRouter.call(nil)
    {conn.status, conn.resp_body}
  end

  test "/health is 503 while a Storage child is down and 200 once it is back" do
    assert health() == {200, "ok"}

    :ok = Supervisor.terminate_child(Storage, Storage.LoadedSegments)
    on_exit(fn -> Supervisor.restart_child(Storage, Storage.LoadedSegments) end)
    refute Storage.ready?()
    assert health() == {503, "storage unavailable"}

    {:ok, _pid} = Supervisor.restart_child(Storage, Storage.LoadedSegments)
    assert health() == {200, "ok"}
  end

  test "every Storage child is registered under its id, SegmentExpiration last" do
    {:ok, {_flags, specs}} = Storage.init([])
    ids = Enum.map(specs, & &1.id)

    assert List.last(ids) == Storage.SegmentExpiration
    assert Enum.all?(ids, &is_pid(Process.whereis(&1)))
  end
end
