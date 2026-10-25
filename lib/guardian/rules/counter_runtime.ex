defmodule Guardian.Rules.CounterRuntime do
  @moduledoc "Bucket expansion and combination for resolved TRACK/LOOKUP counter plans."
  alias Guardian.Aggregation
  alias Guardian.Counters.{KeyMachines, Machine}

  @counts [{"count", 0}, {"count", 1}]

  def lookup(definition, group, event) do
    definition |> expand_lookup(group, event) |> run(definition.aggregation, event)
  end

  def track(definition, group, values, event) do
    definition |> expand_track(group, values, event) |> run(definition.aggregation, event)
  end

  def expand_lookup(definition, group, event) do
    Enum.map(keys(definition, group, event), &KeyMachines.read/1)
  end

  def expand_track(definition, group, values, event) do
    operator = definition.operator
    aggregation = definition.aggregation
    delta = Aggregation.start(aggregation, values)
    keys = keys(definition, group, event)

    if operator in @counts and delta == 0 do
      Enum.map(keys, &KeyMachines.read/1)
    else
      {current, previous} = List.pop_at(keys, -1)
      expiry = expiry(definition, event)

      writer =
        if operator in @counts,
          do: KeyMachines.incr(current, delta, expiry),
          else: KeyMachines.merge(aggregation, current, delta, expiry)

      # Keep the current bucket last: min/max ties and floating sums depend on order.
      Enum.map(previous, &KeyMachines.read/1) ++ [writer]
    end
  end

  def combine(aggregation, results) do
    if Enum.any?(results, &match?({:error, _}, &1)) do
      missing(aggregation)
    else
      results
      |> Enum.reduce(Aggregation.empty(aggregation), fn
        :not_found, acc -> acc
        {:ok, state}, acc -> Aggregation.merge(aggregation, acc, state)
      end)
      |> then(&Aggregation.finish(aggregation, &1))
    end
  end

  def missing(aggregation) do
    Aggregation.default(aggregation)
  end

  defp run(machines, aggregation, event) do
    [results] = Machine.run_nested([machines], event.counters)
    combine(aggregation, results)
  end

  defp keys(definition, group, event) do
    first = Integer.floor_div(event.arrival_ms - definition.window_ms, definition.bucket_ms)
    last = Integer.floor_div(event.arrival_ms, definition.bucket_ms)
    for bucket <- first..last, do: {definition.identity, group, bucket}
  end

  defp expiry(definition, event) do
    bucket = Integer.floor_div(event.arrival_ms, definition.bucket_ms)
    unix_expiry = (bucket + 1) * definition.bucket_ms + definition.window_ms
    event.monotonic_ms + unix_expiry - event.arrival_ms
  end
end
