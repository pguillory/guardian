defmodule Guardian.Query.Function.Log do
  # Zero and negatives have no logarithm: null.
  def eval(value) when is_number(value) and value > 0 do
    :math.log(value)
  end

  def eval(_) do
    nil
  end
end
