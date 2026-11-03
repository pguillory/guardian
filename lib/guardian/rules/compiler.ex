defmodule Guardian.Rules.Compiler do
  @moduledoc """
  Compiles one table's resolved `Guardian.Rules.Plan` into the binary of a generated
  module with `apply/2`, which runs the table's dependency levels on a flattened row
  and returns the new row, plus `table/0` and `hash/0` (Publisher reuses a module
  whose hash is unchanged). `apply/1` creates a fresh event context. Compiling loads
  nothing: `Guardian.Rules.Publisher` loads the binaries once every changed table has
  compiled. Unresolved candidates return `:unresolved_plan`; a LOOKUP without a bound
  target returns `:unbound_lookup`.

  The module comes only from the fixed template below, in Erlang abstract format: the
  plan's dependency levels, derived from its flat steps once at compile time, are one
  literal for `Guardian.Rules.Runtime.run/3`. No rule text becomes code. Expressions
  are evaluated by the query engine's scalar evaluator; generating native code per
  expression is a later optimization. AST literals hold regular expressions as pattern
  strings, never compiled `:re` references.

  Each table has one module, named from the table (`module_name/1`), so atoms are
  bounded by the number of tables; a change replaces that module in place.
  """

  @prefix "Elixir.Guardian.Rules.Compiled."

  @doc """
  The module name of `table`'s rules: the table name, verbatim, under
  `Guardian.Rules.Compiled`. Table names are dot-free, so distinct tables get distinct
  names, and start with a lowercase letter or `_`, which no Elixir alias can, so no
  source module has one of these names. At most 95 characters. Raises for an invalid
  table name, which only a bug can pass.
  """
  def module_name(table) do
    if not Guardian.Engine.valid_table_name?(table) do
      raise ArgumentError, "not a valid table name: #{inspect(table)}"
    end

    # The one string-to-atom conversion in lib/: bounded by the tables that have
    # rules, which only the admin key can write (docs/architecture/security.md).
    String.to_atom(@prefix <> table)
  end

  @doc "Whether `module` is a generated rules module."
  def generated?(module) do
    String.starts_with?(Atom.to_string(module), @prefix)
  end

  @doc """
  Compiles `plan` as `module`, without loading it. Returns `{:ok, binary}` or
  `{:error, kind}`.
  """
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

    case :compile.forms(forms(module, plan, levels), [:binary, :return_errors]) do
      {:ok, ^module, binary} -> {:ok, binary}
      {:error, _errors, _warnings} -> {:error, :compile_error}
    end
  rescue
    # Fails the activation closed; Publisher logs it. The file is already saved, so
    # raising would crash Rules.Server on every node that reads the set, past its
    # restart limit, and then refuse their boot.
    e -> {:error, inspect(e.__struct__)}
  end

  # -module(Module).
  # table() -> Table.  hash() -> Hash.
  # apply(Row) -> Module:apply(Row, 'Elixir.Guardian.Rules.Event':new()).
  # apply(Row, Event) -> 'Elixir.Guardian.Rules.Runtime':run(Row, levels(), Event).
  # levels() -> Levels.
  defp forms(module, plan, levels) do
    row = {:var, 1, :Row}
    event = {:var, 1, :Event}

    [
      {:attribute, 1, :file, {~c"rules/#{plan.table}", 1}},
      {:attribute, 1, :module, module},
      {:attribute, 1, :export, [table: 0, hash: 0, apply: 1, apply: 2]},
      function(:table, [], :erl_parse.abstract(plan.table)),
      function(:hash, [], :erl_parse.abstract(plan.hash)),
      function(
        :apply,
        [row],
        remote(module, :apply, [row, remote(Guardian.Rules.Event, :new, [])])
      ),
      function(
        :apply,
        [row, event],
        remote(Guardian.Rules.Runtime, :run, [row, {:call, 1, {:atom, 1, :levels}, []}, event])
      ),
      function(:levels, [], :erl_parse.abstract(levels)),
    ]
  end

  defp function(name, args, body) do
    {:function, 1, name, length(args), [{:clause, 1, args, [], [body]}]}
  end

  defp remote(module, function, args) do
    {:call, 1, {:remote, 1, {:atom, 1, module}, {:atom, 1, function}}, args}
  end
end
