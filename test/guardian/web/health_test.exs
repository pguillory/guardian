defmodule Guardian.Web.HealthTest do
  use ExUnit.Case, async: true

  defp health do
    conn = Plug.Test.conn(:get, "/health") |> Guardian.Web.MainRouter.call(nil)
    {conn.status, conn.resp_body}
  end

  test "/health is 200 ok" do
    assert health() == {200, "ok"}
  end

  test "every Storage child is registered under its id, SegmentExpiration last" do
    {:ok, {_flags, specs}} = Guardian.Storage.init([])
    ids = Enum.map(specs, & &1.id)

    assert List.last(ids) == Guardian.Storage.SegmentExpiration
    assert Enum.all?(ids, &is_pid(Process.whereis(&1)))
  end
end
