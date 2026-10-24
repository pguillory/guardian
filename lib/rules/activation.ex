defmodule Rules.Activation do
  @moduledoc """
  Pure selection for rule activation. An invalid dependency component retains its
  previous valid plans together, including deleted tables.
  Tables without a previous valid plan in that component are invalid until the
  whole component validates. Empty previous plans select directed boot semantics.

  Edges include previous bound LOOKUP targets and new locally valid candidates,
  so an invalid dependent cannot strand an old identity when its target changes.
  Server uses counter-refusing preparation until public enablement in C4c3. Its previous
  plans come from the published modules' recoverable metadata, so selection also
  preserves prior plans after Server restarts. With counters disabled, components
  are individual tables.
  Selection returns tables/retained; the caller must combine preparation.errors
  with selected table errors so retained failures and deferral diagnostics survive.
  """

  def select(preparation, previous \\ %{})

  def select(preparation, previous) when map_size(previous) == 0,
    do: %{tables: preparation.tables, retained: MapSet.new()}

  def select(preparation, previous) do
    edges = dependencies(preparation.candidates, previous)
    failed = for {table, {:error, _}} <- preparation.tables, do: table
    retained = Enum.reduce(failed, MapSet.new(), &connected(&1, edges, &2))

    tables =
      Enum.reduce(retained, preparation.tables, fn table, tables ->
        case Map.fetch(previous, table) do
          {:ok, plan} -> Map.put(tables, table, {:ok, plan})
          :error -> defer_new(tables, table, failed, edges)
        end
      end)

    %{tables: tables, retained: MapSet.intersection(retained, MapSet.new(Map.keys(previous)))}
  end

  defp dependencies(candidates, previous) do
    old =
      for {table, plan} <- previous,
          %Rules.Step.Lookup{target: %Rules.CounterDefinition{identity: {target_table, _, _}}} <-
            plan.steps,
          do: {table, target_table}

    new =
      for {table, {:ok, plan}} <- candidates,
          %Rules.Step.Lookup{target_table: target_table} <- plan.steps,
          do: {table, target_table}

    Enum.reduce(old ++ new, %{}, fn {left, right}, edges ->
      edges
      |> Map.update(left, MapSet.new([right]), &MapSet.put(&1, right))
      |> Map.update(right, MapSet.new([left]), &MapSet.put(&1, left))
    end)
  end

  defp connected(table, edges, visited) do
    if table in visited do
      visited
    else
      Enum.reduce(Map.get(edges, table, MapSet.new()), MapSet.put(visited, table), fn next,
                                                                                      seen ->
        connected(next, edges, seen)
      end)
    end
  end

  defp defer_new(tables, table, failed, edges) do
    case Map.get(tables, table) do
      {:ok, _plan} ->
        component = connected(table, edges, MapSet.new())
        cause = failed |> Enum.filter(&(&1 in component)) |> Enum.sort() |> Enum.join(", ")

        error =
          Rules.Validation.error(
            "#{table}/",
            nil,
            :reload_dependency,
            table,
            "activation deferred by an invalid counter dependency component (#{cause})",
            table
          )

        Map.put(tables, table, {:error, [error]})

      _ ->
        tables
    end
  end
end
