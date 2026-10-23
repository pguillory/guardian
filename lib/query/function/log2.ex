defmodule Query.Function.Log2 do
  def eval(value) when is_number(value) do
    :math.log2(value)
  end

  def eval(_) do
    nil
  end
end
