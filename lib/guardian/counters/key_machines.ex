defmodule Guardian.Counters.KeyMachines do
  @moduledoc "Read, atomic increment and bounded gets/merge/CAS machines for one bucket."
  alias Guardian.Counters.{Aggregate, Machine}

  def read(key), do: Machine.new({:get, key}, nil, &read_response/3)

  def incr(key, delta, expiry),
    do: Machine.new({:incr, key, delta, {:expires, expiry}}, nil, &read_response/3)

  def merge(operator, key, delta, expiry) do
    state = %{operator: operator, delta: delta, expiry: expiry, attempts: 3, merged: nil}
    Machine.new({:gets, key}, state, &merge_response/3)
  end

  defp read_response(_, response, _), do: {:done, response}

  defp merge_response({:gets, key}, :not_found, state),
    do: merge_response({:gets, key}, {:ok, Aggregate.default(state.operator), :missing}, state)

  defp merge_response({:gets, key}, {:ok, prior, token}, state) do
    merged = Aggregate.merge(state.operator, prior, state.delta)

    cond do
      # Preserve the old read/expiry/unchanged order; dispatch checks expiry again
      # after any wait for the next owner reservation.
      state.expiry <= System.monotonic_time(:millisecond) ->
        {:done, {:error, :expired}}

      merged === prior ->
        {:done, {:ok, prior}}

      true ->
        {:next, {:cas, key, token, merged, {:expires, state.expiry}}, %{state | merged: merged}}
    end
  end

  defp merge_response({:cas, _, _, _, _}, :ok, state), do: {:done, {:ok, state.merged}}

  defp merge_response({:cas, key, _, _, _}, {:error, :conflict}, %{attempts: n} = state)
       when n > 1,
       do: {:next, {:gets, key}, %{state | attempts: n - 1}}

  defp merge_response(_, error, _), do: {:done, error}
end
