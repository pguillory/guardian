defmodule AST.Node.Operators.Comparison do
  # Not a node: the evaluation shared by `<` and `<=` (and, through their rewrites,
  # `>`, `>=` and BETWEEN).
  @moduledoc false

  alias Query.ColumnOrConstant
  alias Query.Constant
  alias Query.Evaluation

  @doc """
  Evaluates `left OP right` over `context`. `eval_fun` is the operator's row-by-row
  `eval/2`; `compare` is the same comparison on two numbers.

  When one side is a number literal, the other side's number range can answer a whole
  segment at once: every row is null when it holds no numbers, every number row is
  true when the whole range is on the true side (and false when it is on the false
  side), with every other row null; anything else is evaluated row by row.
  """
  def eval(%{left: left, right: right}, context, eval_fun, compare) do
    column1 = Query.Eval.eval(left, context)
    column2 = Query.Eval.eval(right, context)

    case {left, right} do
      {%AST.Node.Literal{value: literal}, _right} when is_number(literal) ->
        case ColumnOrConstant.min_max_number(column2) do
          {nil, nil} ->
            Constant.duplicate(nil, Evaluation.context_count(context))

          {min, max} ->
            cond do
              is_number(min) and compare.(literal, min) ->
                ColumnOrConstant.number_to_true(column2)

              is_number(max) and not compare.(literal, max) ->
                ColumnOrConstant.number_to_false(column2)

              true ->
                ColumnOrConstant.map(column1, column2, eval_fun)
            end
        end

      {_left, %AST.Node.Literal{value: literal}} when is_number(literal) ->
        case ColumnOrConstant.min_max_number(column1) do
          {nil, nil} ->
            Constant.duplicate(nil, Evaluation.context_count(context))

          {min, max} ->
            cond do
              is_number(max) and compare.(max, literal) ->
                ColumnOrConstant.number_to_true(column1)

              is_number(min) and not compare.(min, literal) ->
                ColumnOrConstant.number_to_false(column1)

              true ->
                ColumnOrConstant.map(column1, column2, eval_fun)
            end
        end

      _ ->
        ColumnOrConstant.map(column1, column2, eval_fun)
    end
  end
end
