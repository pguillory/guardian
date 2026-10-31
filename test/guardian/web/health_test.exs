defmodule Guardian.Web.HealthTest do
  use ExUnit.Case, async: true

  defp health do
    conn = Plug.Test.conn(:get, "/health") |> Guardian.Web.MainRouter.call(nil)
    {conn.status, conn.resp_body}
  end

  test "/health is 200 ok" do
    assert health() == {200, "ok"}
  end

  # `Guardian.Storage.ready?/0` looks up names, and relies on MutableSegments starting
  # after ReadableSegments has loaded every file.
  test "every Storage process is registered, MutableSegments after ReadableSegments" do
    {:ok, {_flags, specs}} = Guardian.Storage.init([])

    [
      %{id: schema},
      %{id: :segments, start: {Supervisor, :start_link, [group, _]}},
      %{id: expiration},
    ] =
      specs

    names =
      Enum.map(group, fn
        {DynamicSupervisor, opts} -> Keyword.fetch!(opts, :name)
        module -> module
      end)

    assert names == [
             Guardian.Storage.SegmentSupervisor,
             Guardian.Storage.ReadableSegments,
             Guardian.Storage.MutableSegments,
           ]

    for name <- [schema, expiration] ++ names, do: assert(is_pid(Process.whereis(name)))
  end
end
