defmodule Guardian.Query.Function.Power do
  # 0 to a negative power, a negative base to a fractional power, and an overflowing
  # result are null (Guardian.Query.Numeric).
  def eval(value1, value2) when is_number(value1) and is_number(value2) do
    :math.pow(value1, value2)
  catch
    :error, :badarith -> nil
  end

  def eval(_, _) do
    nil
  end
end
