defmodule Guardian.Rules.EventTest do
  use ExUnit.Case, async: true
  import Guardian.Rules.Event
  alias Guardian.Counters.Arrival
  alias Guardian.Counters.Client
  alias Guardian.Counters.Context
  alias Guardian.Rules.Event

  test "starting an Event preserves private arrival coordinates and nests the typed context" do
    arrival = %Arrival{unix_ms: 123, monotonic_ms: -456}
    batch = Client.new_batch()
    first = start(arrival, batch, members: [node()])
    second = start(arrival, batch, members: [node()])

    assert %Event{arrival: ^arrival, counters: %Context{batch: ^batch}} = first
    assert second.arrival == first.arrival
    assert second.counters.batch == first.counters.batch
    assert %Event{arrival: %Arrival{}, counters: %Context{}} = new()
  end
end
