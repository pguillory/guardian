defmodule Rules.Compiler do
  @moduledoc """
  Compiles one table's resolved `Rules.Plan` into a generated module with `apply/2`,
  which runs the table's statements in order on a flattened row and returns the new
  row. `plan/0` recovers the exact immutable plan for reload selection after a
  Server restart. Metadata lives and is reclaimed with its bounded pool module.
  Unresolved candidates return `:unresolved_plan`; a LOOKUP without a bound target
  returns `:unbound_lookup`. `apply/1` creates a fresh event and batch context.

  The module body comes only from the fixed template below: ordered typed steps
  are escaped as literal data for `Rules.Runtime.run/3`. No rule text
  becomes code. Expressions are evaluated by the query engine's scalar evaluator;
  generating native code per expression is a later optimization. AST literals hold
  regular expressions as pattern strings, never compiled `:re` references.

  Module names come from a fixed pool (`name/1`), so atoms stay bounded however often
  rules change; `Rules.Server` owns the pool and never loads a name twice while
  anything can still call it.
  """

  @pool_size 1_024

  def pool_size, do: @pool_size

  @doc "The module name of pool slot `n`."
  def name(n) when n in 0..(@pool_size - 1)//1, do: Module.concat(Rules.Compiled, "M#{n}")

  def names, do: Enum.map(0..(@pool_size - 1), &name/1)

  @doc "Compiles and loads `plan` as `module`. Returns `:ok` or `{:error, kind}`."
  def compile(module, %Rules.Plan{} = plan) do
    cond do
      not plan.resolved? ->
        {:error, :unresolved_plan}

      Enum.any?(plan.steps, &match?(%Rules.Step.Lookup{target: nil}, &1)) ->
        {:error, :unbound_lookup}

      true ->
        compile_resolved(module, plan)
    end
  end

  defp compile_resolved(module, plan) do
    body =
      quote do
        @moduledoc false
        def table, do: unquote(plan.table)
        def hash, do: unquote(plan.hash)
        def plan, do: unquote(Macro.escape(plan))

        # Qualify the local call: unqualified apply/2 resolves to Kernel.apply/2.
        def apply(row), do: __MODULE__.apply(row, Rules.Event.new())

        def apply(row, event) do
          Rules.Runtime.run(row, unquote(Macro.escape(plan.steps)), event)
        end
      end

    {:module, ^module, _binary, _} =
      Module.create(module, body, file: "rules/#{plan.table}", line: 1)

    :ok
  rescue
    e -> {:error, inspect(e.__struct__)}
  end
end
