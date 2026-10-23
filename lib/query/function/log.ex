defmodule Query.Function.Log do
  def eval(value) when is_number(value) do
    :math.log(value)
  end

  def eval(_) do
    nil
  end
end
