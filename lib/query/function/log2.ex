defmodule Query.Function.Log2 do
  # Zero and negatives have no logarithm: null.
  def eval(value) when is_number(value) and value > 0 do
    :math.log2(value)
  end

  def eval(_) do
    nil
  end
end
