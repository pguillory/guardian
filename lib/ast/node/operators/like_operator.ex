defmodule AST.Node.Operators.LikeOperator do
  use AST.Node.BinaryOperator, symbol: "LIKE"

  alias Query.ColumnOrConstant

  defimpl Query.Eval do
    def eval(%@for{left: left, right: right}, context) do
      column1 = Query.Eval.eval(left, context)
      column2 = Query.Eval.eval(right, context)
      ColumnOrConstant.map(column1, column2, &@for.eval/2)
    end
  end

  def eval(<<>>, <<>>) do
    true
  end

  def eval(<<_::binary>>, <<>>) do
    false
  end

  def eval(<<>>, <<"_", _::binary>>) do
    false
  end

  def eval(<<_, left::binary>>, <<"_", right::binary>>) do
    eval(left, right)
  end

  def eval(left, <<"%%", right::binary>>) do
    eval(left, "%" <> right)
  end

  def eval(left, <<"%_", right::binary>>) do
    eval(left, "%" <> right)
  end

  def eval(<<>>, <<"%", right::binary>>) do
    eval(<<>>, right)
  end

  def eval(<<_, rest::binary>> = left, <<"%", right::binary>>) do
    eval(left, right) or eval(rest, "%" <> right)
  end

  def eval(<<>>, <<_, _::binary>>) do
    false
  end

  def eval(<<c, left::binary>>, <<c, right::binary>>) do
    eval(left, right)
  end

  def eval(<<_, _::binary>>, <<_, _::binary>>) do
    false
  end

  def eval(_left, _right) do
    nil
  end
end
