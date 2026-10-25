defmodule Guardian.Query.Function.Sqrt do
  # A negative has no real square root: null.
  def eval(value) when is_number(value) and value >= 0 do
    :math.sqrt(value)
  end

  def eval(_) do
    nil
  end
end
