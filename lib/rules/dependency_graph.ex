defmodule Rules.DependencyGraph do
  @moduledoc """
  Field dependency ordering using Kahn's algorithm, always taking the earliest
  ready statement by file then position. A read of `user.name` depends on the
  definition of `user`; a statement's read of its own field reads the incoming
  value and adds no dependency.
  """

  def order(steps) do
    by_field = Map.new(steps, &{&1.field, &1})

    deps =
      Map.new(steps, fn step ->
        fields =
          step.reads
          |> Enum.map(&top_level/1)
          |> Enum.filter(&(Map.has_key?(by_field, &1) and &1 != step.field))
          |> MapSet.new()

        {step.field, fields}
      end)

    order(Enum.sort_by(steps, &{&1.file, &1.index}), deps, [])
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
