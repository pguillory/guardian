defmodule Query.Function.Sqrt do
  def eval(value) when is_number(value) do
    :math.sqrt(value)
  end

  def eval(_) do
    nil
  end
end
