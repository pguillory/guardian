defmodule Query.Function.Power do
  def eval(value1, value2) when is_number(value1) and is_number(value2) do
    :math.pow(value1, value2)
  end

  def eval(_, _) do
    nil
  end
end
