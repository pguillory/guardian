defmodule Guardian.Rules.Compiler do
  @moduledoc """
  Compiles one table's resolved `Guardian.Rules.Plan` into a generated module with
  `apply/2`, which runs the table's dependency levels on a flattened row and returns
  the new row, plus `table/0` and `hash/0` (Publisher reuses a module whose hash is
  unchanged). Unresolved candidates return `:unresolved_plan`; a LOOKUP without a
  bound target returns `:unbound_lookup`. `apply/1` creates a fresh event and batch
  context.

  The module body comes only from the fixed template below: the plan's dependency
  levels, derived from its flat steps once at compile time, are escaped once as
  literal data for `Guardian.Rules.Runtime.run/3`. No rule text becomes code.
  Expressions are evaluated by the query engine's scalar evaluator; generating native
  code per expression is a later optimization. AST literals hold regular expressions
  as pattern strings, never compiled `:re` references.

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
    levels = Guardian.Rules.DependencyGraph.levels(plan.steps)

    body =
      quote do
        @moduledoc false
        def table do
          unquote(plan.table)
        end

        def hash do
          unquote(plan.hash)
        end

        # Qualify the local call: unqualified apply/2 resolves to Kernel.apply/2.
        def apply(row) do
          __MODULE__.apply(row, Guardian.Rules.Event.new())
        end

        def apply(row, event) do
          Guardian.Rules.Runtime.run(row, levels(), event)
        end

        defp levels do
          unquote(Macro.escape(levels))
        end
      end

    {:module, ^module, _binary, _} =
      Module.create(module, body, file: "rules/#{plan.table}", line: 1)

    :ok
  rescue
    e -> {:error, inspect(e.__struct__)}
  end
end
