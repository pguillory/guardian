defmodule Rules.Resolution do
  @moduledoc """
  Binds LOOKUPs to immutable TRACK definitions and hashes the resulting plans.
  Invalid targets propagate in synchronous rounds to a fixed point. Target
  identities, never target plan hashes, allow reciprocal table references.
  """

  def resolve(candidates), do: resolve(candidates, candidates)

  defp resolve(candidates, current) do
    definitions =
      for {table, {:ok, plan}} <- current,
          %Rules.Step.Track{} = track <- plan.steps,
          into: %{},
          do: {{table, track.field}, Rules.CounterDefinition.from_track(track)}

    next =
      Map.new(candidates, fn
        {table, {:ok, plan}} ->
          result =
            case Map.fetch!(current, table) do
              {:error, _} = error -> error
              {:ok, _} -> bind(plan, definitions)
            end

          {table, result}

        entry ->
          entry
      end)

    if invalid_tables(next) == invalid_tables(current),
      do: next,
      else: resolve(candidates, next)
  end

  defp invalid_tables(tables),
    do: for({table, {:error, _}} <- tables, into: MapSet.new(), do: table)

  defp bind(plan, definitions) do
    {steps, errors} =
      Enum.map_reduce(plan.steps, [], fn
        %Rules.Step.Lookup{} = step, errors ->
          case target(step, definitions) do
            {:ok, definition} -> {%{step | target: definition}, errors}
            {:error, error} -> {step, errors ++ [error]}
          end

        step, errors ->
          {step, errors}
      end)

    case errors do
      [] ->
        {:ok,
         %{
           plan
           | steps: steps,
             levels: Rules.DependencyGraph.levels(steps),
             hash: hash(plan.hash, steps),
             resolved?: true,
         }}

      _ ->
        {:error, errors}
    end
  end

  defp target(step, definitions) do
    definition = Map.get(definitions, {step.target_table, step.counter})

    detail = {step.field, step.target_table, step.counter}

    cond do
      is_nil(definition) ->
        {:error,
         Rules.Validation.error(
           step,
           :counter_target,
           detail,
           "LOOKUP must reference a TRACK on a valid target table"
         )}

      length(step.by_exprs) != definition.group_arity ->
        {:error,
         Rules.Validation.error(
           step,
           :counter_arity,
           detail,
           "LOOKUP must supply the target TRACK's number of BY expressions"
         )}

      true ->
        {:ok, definition}
    end
  end

  # Preserve the existing SET/UNSET hash exactly. A LOOKUP's binding adds only its
  # target definition, so moving a target between files does not reset dependents.
  defp hash(base_hash, steps) do
    targets = for %Rules.Step.Lookup{target: target} <- steps, do: target

    case targets do
      [] ->
        base_hash

      _ ->
        :crypto.hash(:sha256, :erlang.term_to_binary({base_hash, targets}))
        |> Base.encode16(case: :lower)
    end
  end
end
