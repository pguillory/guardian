defmodule Guardian.Counters.ContextTest do
  use ExUnit.Case, async: true
  alias Guardian.Counters.Client
  alias Guardian.Counters.Context
  alias Guardian.Counters.Store

  test "Client captures a typed context with the local node first and the default store" do
    context = Client.new_event()
    assert %Context{store: Store} = context
    assert is_integer(context.timeout_ms) and context.timeout_ms > 0
    assert [local | peers] = context.members
    assert local == node()
    assert Enum.all?(peers, &is_atom/1)
  end

  test "options replace the call timeout, members and store" do
    members = [:counter_context@localhost]
    context = Client.new_event(timeout_ms: 7, members: members, store: self())
    assert context == %Context{timeout_ms: 7, members: members, store: self()}
  end
end
