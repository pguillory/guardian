defmodule Guardian.AST.Node.FunctionCall do
  use Guardian.AST.Node

  alias Guardian.Query.ColumnOrConstant
  alias Guardian.Query.Constant
  alias Guardian.Query.Evaluation

  @enforce_keys [:name, :args]
  defstruct [:name, :args]

  defimpl Guardian.Query.Eval do
    # A function module that defines `eval2/2` evaluates the call itself; otherwise the
    # call is evaluated row by row with the module's `eval/N`
    # (lib/query/function/CLAUDE.md).
    def eval(%@for{name: name, args: args} = expr, context) do
      arity = length(args)

      case Guardian.Query.Function.name_and_arity_to_mod(name, arity) do
        {:ok, mod} ->
          Code.ensure_loaded!(mod)

          if function_exported?(mod, :eval2, 2) do
            # eval2 is optional; the type checker cannot narrow modules by the export check.
            apply(mod, :eval2, [context, expr])
          else
            eval_per_row(context, mod, args, arity)
          end

        {:error, :not_found} ->
          Constant.duplicate(nil, Evaluation.context_count(context))
      end
    end

    defp eval_per_row(context, mod, [], 0) do
      ColumnOrConstant.generate(&mod.eval/0, Evaluation.context_count(context))
    end

    defp eval_per_row(context, mod, args, arity) do
      columns = Enum.map(args, &Guardian.Query.Eval.eval(&1, context))
      eval = Function.capture(mod, :eval, arity)

      case columns do
        [column1] ->
          ColumnOrConstant.map(column1, eval)

        [column1, column2] ->
          ColumnOrConstant.map(column1, column2, eval)

        [column1, column2, column3] ->
          ColumnOrConstant.map(column1, column2, column3, eval)

        [column1, column2, column3, column4] ->
          ColumnOrConstant.map(column1, column2, column3, column4, eval)

        # Unreachable today: no function registered above arity 4 lacks its own eval2.
        _ ->
          raise ArgumentError,
                "#{inspect(mod)} needs its own eval2/2 for #{arity} arguments"
      end
    end
  end

  def to_source(%__MODULE__{name: name, args: args}) do
    name <> "(" <> Enum.map_join(args, ", ", &Guardian.AST.unparse/1) <> ")"
  end

  def traverse(%__MODULE__{} = expr, acc, pre, post) do
    traverse_fields(expr, [:args], acc, pre, post)
  end
end
