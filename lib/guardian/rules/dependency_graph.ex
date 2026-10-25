defmodule Guardian.Rules.DependencyGraph do
  @moduledoc """
  Field dependency ordering using Kahn's algorithm. LOOKUPs and their prerequisites
  take priority; within each phase the earliest ready statement runs by file then
  position. A read of `user.name` depends on the
  definition of `user`; a statement's read of its own field reads the incoming
  value and adds no dependency.
  """

  def order(steps) do
    deps = dependencies(steps)

    first_phase = lookup_ancestors(steps, deps)

    ordered =
      Enum.sort_by(steps, &{if(&1.field in first_phase, do: 0, else: 1), &1.file, &1.index})

    order(ordered, deps, [])
  end

  @doc "Dependency levels, draining LOOKUP ancestors before any TRACK and UNSETs last."
  def levels(steps) do
    {unsets, steps} = Enum.split_with(steps, &(&1.kind == :unset))
    deps = dependencies(steps)

    first = lookup_ancestors(steps, deps)

    {lookups, rest} = Enum.split_with(steps, &(&1.field in first))
    {before, deps} = levels(lookups, deps, [])
    {afterwards, _} = levels(rest, deps, [])
    before ++ afterwards ++ Enum.map(unsets, &[&1])
  end

  defp lookup_ancestors(steps, deps) do
    steps
    |> Enum.filter(&(&1.kind == :lookup))
    |> Enum.reduce(MapSet.new(), fn step, acc ->
      MapSet.union(acc, ancestors(step.field, deps, MapSet.new()))
    end)
  end

  defp levels([], deps, acc), do: {Enum.reverse(acc), deps}

  defp levels(pending, deps, acc) do
    {ready, waiting} = Enum.split_with(pending, &(MapSet.size(Map.fetch!(deps, &1.field)) == 0))
    if ready == [], do: raise(ArgumentError, "cyclic rule levels")
    ready = Enum.sort_by(ready, &{&1.file, &1.index})
    fields = MapSet.new(ready, & &1.field)
    deps = Map.new(deps, fn {field, reads} -> {field, MapSet.difference(reads, fields)} end)
    levels(waiting, deps, [ready | acc])
  end

  @doc "LOOKUPs whose input expressions transitively read TRACK outputs on this table."
  def barrier_violations(steps) do
    deps = dependencies(steps)
    tracks = steps |> Enum.filter(&(&1.kind == :track)) |> MapSet.new(& &1.field)

    Enum.filter(steps, fn step ->
      step.kind == :lookup and
        not MapSet.disjoint?(
          MapSet.delete(ancestors(step.field, deps, MapSet.new()), step.field),
          tracks
        )
    end)
  end

  defp dependencies(steps) do
    by_field = Map.new(steps, &{&1.field, &1})

    Map.new(steps, fn step ->
      fields =
        step.reads
        |> Enum.map(&top_level/1)
        |> Enum.filter(&(Map.has_key?(by_field, &1) and &1 != step.field))
        |> MapSet.new()

      {step.field, fields}
    end)
  end

  defp ancestors(field, deps, visited) do
    if field in visited do
      visited
    else
      Enum.reduce(Map.fetch!(deps, field), MapSet.put(visited, field), fn dep, seen ->
        ancestors(dep, deps, seen)
      end)
    end
  end

  @doc "The top-level field of a field name or path."
  def top_level(name), do: name |> String.split(".", parts: 2) |> hd()

  defp order([], _deps, acc), do: {:ok, Enum.reverse(acc)}

  defp order(pending, deps, acc) do
    case Enum.find(pending, &(MapSet.size(Map.fetch!(deps, &1.field)) == 0)) do
      nil ->
        {:cycle, pending}

      ready ->
        deps =
          Map.new(deps, fn {field, fields} ->
            {field, MapSet.delete(fields, ready.field)}
          end)

        order(List.delete(pending, ready), deps, [ready | acc])
    end
  end
end
