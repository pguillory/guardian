defmodule Rules.Compiler do
  @moduledoc """
  Compiles one table's `Rules.Plan` into a generated module with `apply/1`, which runs
  the table's statements in order on a flattened row and returns the new row.

  The module body comes only from the fixed template below: each statement becomes one
  call to `Rules.Runtime.set/3` or `unset/3` with the statement (field, expressions as
  AST, the names it reads, its file and line) escaped as a literal. No rule text
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
    steps =
      Enum.map(plan.steps, fn step ->
        literal =
          Macro.escape(%{
            file: step.file,
            line: step.line,
            field: step.field,
            value_expr: step.value_expr,
            where_expr: step.where_expr,
            reads: step.reads,
          })

        case step.kind do
          :set -> quote(do: row = Rules.Runtime.set(row, index, unquote(literal)))
          :unset -> quote(do: row = Rules.Runtime.unset(row, index, unquote(literal)))
        end
      end)

    body =
      quote do
        @moduledoc false
        def table, do: unquote(plan.table)
        def hash, do: unquote(plan.hash)

        def apply(row) do
          index = Rules.Runtime.index(row)
          unquote_splicing(steps)
          _ = index
          row
        end
      end

    {:module, ^module, _binary, _} =
      Module.create(module, body, file: "rules/#{plan.table}", line: 1)

    :ok
  rescue
    e -> {:error, inspect(e.__struct__)}
  end
end
