defmodule Query.Function.Exp do
  def eval(value) when is_number(value) do
    :math.exp(value)
  end

  def eval(_) do
    nil
  end
end
