defmodule Rules.CounterRuntime do
  @moduledoc "Bucket execution for resolved TRACK/LOOKUP plans with fail-open aggregate defaults."
  alias Counters.{Aggregate, Cluster}

  @cas_attempts 3
  @counts [{"count", 0}, {"count", 1}]

  def lookup(definition, group, event) do
    with {:ok, states} <- read(keys(definition, group, event), definition.operator, event) do
      resolve(definition.operator, states)
    else
      _ -> missing(definition.operator)
    end
  end

  def track(definition, group, values, event) do
    operator = definition.operator
    delta = Aggregate.create(operator, values)
    keys = keys(definition, group, event)

    if operator in @counts and delta == 0 do
      lookup(definition, group, event)
    else
      {current, previous} = List.pop_at(keys, -1)
      expiry = expiry(definition, event)

      with true <- remaining(expiry) > 0,
           {:ok, states} <- read(previous, operator, event),
           {:ok, state} <- update(current, operator, delta, expiry, event) do
        resolve(operator, states ++ [state])
      else
        _ -> missing(operator)
      end
    end
  end

  def missing(operator), do: Aggregate.resolve(operator, Aggregate.default(operator))

  defp keys(definition, group, event) do
    first = Integer.floor_div(event.arrival_ms - definition.window_ms, definition.bucket_ms)
    last = Integer.floor_div(event.arrival_ms, definition.bucket_ms)
    for bucket <- first..last, do: {definition.identity, group, bucket}
  end

  # Translate the fixed Unix expiry once onto this event's private monotonic clock.
  # Store receives remaining durations; dispatch/queue transit may still delay expiry.
  defp expiry(definition, event) do
    bucket = Integer.floor_div(event.arrival_ms, definition.bucket_ms)
    unix_expiry = (bucket + 1) * definition.bucket_ms + definition.window_ms
    event.monotonic_ms + unix_expiry - event.arrival_ms
  end

  defp remaining(expiry), do: expiry - System.monotonic_time(:millisecond)

  defp read(keys, operator, event) do
    case Cluster.get_many(keys, event.counters) do
      {:ok, results} ->
        {:ok,
         Enum.map(results, fn
           :not_found -> Aggregate.default(operator)
           {:ok, state} -> state
         end)}

      error ->
        error
    end
  end

  defp resolve(operator, states) do
    state = Enum.reduce(states, Aggregate.default(operator), &Aggregate.merge(operator, &2, &1))
    Aggregate.resolve(operator, state)
  end

  defp update(key, operator, delta, expiry, event)
       when operator in @counts do
    ttl = remaining(expiry)
    if ttl > 0, do: Cluster.incr(key, delta, ttl, event.counters), else: {:error, :expired}
  end

  defp update(key, operator, delta, expiry, event),
    do: compare_and_swap(key, operator, delta, expiry, event, @cas_attempts)

  defp compare_and_swap(_key, _operator, _delta, _expiry, _event, 0),
    do: {:error, :conflict}

  defp compare_and_swap(key, operator, delta, expiry, event, attempts) do
    case Cluster.gets(key, event.counters) do
      :not_found ->
        merge_and_swap(
          key,
          :missing,
          Aggregate.default(operator),
          operator,
          delta,
          expiry,
          event,
          attempts
        )

      {:ok, prior, token} ->
        merge_and_swap(key, token, prior, operator, delta, expiry, event, attempts)

      error ->
        error
    end
  end

  defp merge_and_swap(key, token, prior, operator, delta, expiry, event, attempts) do
    merged = Aggregate.merge(operator, prior, delta)
    ttl = remaining(expiry)

    cond do
      ttl <= 0 ->
        {:error, :expired}

      merged === prior ->
        {:ok, prior}

      true ->
        case Cluster.cas(key, token, merged, ttl, event.counters) do
          :ok ->
            {:ok, merged}

          {:error, :conflict} ->
            compare_and_swap(key, operator, delta, expiry, event, attempts - 1)

          error ->
            error
        end
    end
  end
end
