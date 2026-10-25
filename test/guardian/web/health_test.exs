defmodule Guardian.Web.HealthTest do
  # Not async: it stops and restarts a Storage child.
  use ExUnit.Case, async: false

  defp health do
    conn = Plug.Test.conn(:get, "/health") |> Guardian.Web.MainRouter.call(nil)
    {conn.status, conn.resp_body}
  end

  test "/health is 503 while a Storage child is down and 200 once it is back" do
    assert health() == {200, "ok"}

    :ok = Supervisor.terminate_child(Guardian.Storage, Guardian.Storage.LoadedSegments)
    on_exit(fn -> Supervisor.restart_child(Guardian.Storage, Guardian.Storage.LoadedSegments) end)
    refute Guardian.Storage.ready?()
    assert health() == {503, "storage unavailable"}

    {:ok, _pid} = Supervisor.restart_child(Guardian.Storage, Guardian.Storage.LoadedSegments)
    assert health() == {200, "ok"}
  end

  test "every Storage child is registered under its id, SegmentExpiration last" do
    {:ok, {_flags, specs}} = Guardian.Storage.init([])
    ids = Enum.map(specs, & &1.id)

    assert List.last(ids) == Guardian.Storage.SegmentExpiration
    assert Enum.all?(ids, &is_pid(Process.whereis(&1)))
  end
end
