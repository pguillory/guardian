defmodule Guardian.Counters.Machine do
  @moduledoc "One key operation per round, advanced by a response callback."
  defstruct [:op, :state, :callback]

  def new(op, state, callback) do
    %__MODULE__{op: op, state: state, callback: callback}
  end

  def run_nested(lists, event, execute \\ &Guardian.Counters.Cluster.batch/2) do
    running = lists |> Enum.concat() |> Enum.with_index() |> Map.new(fn {m, id} -> {id, m} end)
    results = loop(running, %{}, event, execute)

    {nested, _} =
      Enum.map_reduce(lists, 0, fn list, offset ->
        {Enum.map(Enum.with_index(list, offset), fn {_, id} -> Map.fetch!(results, id) end),
         offset + length(list)}
      end)

    nested
  end

  defp loop(running, done, _event, _execute) when map_size(running) == 0 do
    done
  end

  defp loop(running, done, event, execute) do
    responses = execute.(Map.new(running, fn {id, machine} -> {id, machine.op} end), event)

    {running, done} =
      Enum.reduce(running, {%{}, done}, fn {id, machine}, {running, done} ->
        case advance(machine, Map.fetch!(responses, id)) do
          {:next, op, state} ->
            {Map.put(running, id, %{machine | op: op, state: state}), done}

          {:done, result} ->
            {running, Map.put(done, id, result)}
        end
      end)

    loop(running, done, event, execute)
  end

  defp advance(machine, response) do
    machine.callback.(machine.op, response, machine.state)
  catch
    _, _ -> {:done, {:error, :invalid_state}}
  end
end
