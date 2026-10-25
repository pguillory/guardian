defmodule Guardian.Rules.Compiler do
  @moduledoc """
  Compiles one table's resolved `Guardian.Rules.Plan` into a generated module with `apply/2`,
  which runs the table's dependency levels on a flattened row and returns the new
  row. `plan/0` recovers the exact immutable plan for activation selection,
  including after a Server restart. Metadata lives and is reclaimed with its
  bounded pool module.
  Unresolved candidates return `:unresolved_plan`; a LOOKUP without a bound target
  returns `:unbound_lookup`. `apply/1` creates a fresh event and batch context.

  The module body comes only from the fixed template below: dependency levels of typed steps
  are escaped once as literal data for `Guardian.Rules.Runtime.run/3`. Flat metadata
  order is recovered from compile-time positions only when `plan/0` is called,
  never during ingestion. No rule text becomes code. Expressions are evaluated
  by the query engine's scalar evaluator; generating native code per expression
  is a later optimization. AST literals hold regular expressions as pattern strings,
  never compiled `:re` references.

  Module names come from a fixed pool (`name/1`), so atoms stay bounded however often
  rules change; `Guardian.Rules.Publisher` owns the pool and never loads a name twice while
  anything can still call it.
  """

  @pool_size 1_024

  def pool_size do
    @pool_size
  end

  @doc "The module name of pool slot `n`."
  def name(n) when n in 0..(@pool_size - 1)//1 do
    Module.concat(Guardian.Rules.Compiled, "M#{n}")
  end

  def names do
    Enum.map(0..(@pool_size - 1), &name/1)
  end

  @doc "Compiles and loads `plan` as `module`. Returns `:ok` or `{:error, kind}`."
  def compile(module, %Guardian.Rules.Plan{} = plan) do
    cond do
      not plan.resolved? ->
        {:error, :unresolved_plan}

      Enum.any?(plan.steps, &match?(%Guardian.Rules.Step.Lookup{target: nil}, &1)) ->
        {:error, :unbound_lookup}

      true ->
        compile_resolved(module, plan)
    end
  end

  defp compile_resolved(module, plan) do
    # Resolution builds levels from these exact steps, but their flat orders can differ.
    # Equal step terms can share a position without changing the recovered plan.
    positions = plan.levels |> List.flatten() |> Enum.with_index() |> Map.new()
    step_order = Enum.map(plan.steps, &Map.fetch!(positions, &1))
    metadata = %{plan | steps: [], levels: []}

    body =
      quote do
        @moduledoc false
        def table do
          unquote(plan.table)
        end

        def hash do
          unquote(plan.hash)
        end

        def plan do
          execution_levels = levels()
          steps = execution_levels |> List.flatten() |> List.to_tuple()

          %{
            unquote(Macro.escape(metadata))
            | steps: Enum.map(unquote(step_order), &elem(steps, &1)),
              levels: execution_levels,
          }
        end

        # Qualify the local call: unqualified apply/2 resolves to Kernel.apply/2.
        def apply(row) do
          __MODULE__.apply(row, Guardian.Rules.Event.new())
        end

        def apply(row, event) do
          Guardian.Rules.Runtime.run(row, levels(), event)
        end

        defp levels do
          unquote(Macro.escape(plan.levels))
        end
      end

    {:module, ^module, _binary, _} =
      Module.create(module, body, file: "rules/#{plan.table}", line: 1)

    :ok
  rescue
    e -> {:error, inspect(e.__struct__)}
  end
end
