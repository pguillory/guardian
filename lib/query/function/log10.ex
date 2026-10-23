defmodule Query.Function.Log10 do
  def eval(value) when is_number(value) do
    :math.log10(value)
  end

  def eval(_) do
    nil
  end
end
