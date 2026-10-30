defmodule Guardian.ApplicationTest do
  # The stopping flag is shared by the whole VM.
  use ExUnit.Case, async: false

  test "new queries are refused and peers told not ready once the machine begins to stop" do
    state = make_ref()
    assert Guardian.Application.prep_stop(state) == state

    try do
      assert Guardian.Query.execute("select 1") ==
               {:error, "this machine is shutting down; retry"}

      refute Guardian.Storage.ready?()
    after
      :persistent_term.erase({Guardian.Application, :stopping})
    end

    assert {:ok, _labels, [[1]]} = Guardian.Query.execute("select 1")
    assert Guardian.Storage.ready?()
  end
end
