defmodule Query.Function.Exp do
  # An overflowing result is null (Query.Numeric).
  def eval(value) when is_number(value) do
    :math.exp(value)
  catch
    :error, :badarith -> nil
  end

  def eval(_) do
    nil
  end
end
