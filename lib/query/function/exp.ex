defmodule Guardian.Query.Function.Exp do
  # An overflowing result is null (Guardian.Query.Numeric).
  def eval(value) when is_number(value) do
    :math.exp(value)
  catch
    :error, :badarith -> nil
  end

  def eval(_) do
    nil
  end
end
