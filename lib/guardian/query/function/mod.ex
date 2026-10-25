defmodule Guardian.Query.Function.Mod do
  # Division by zero is null.
  def eval(value1, value2) when is_integer(value1) and is_integer(value2) and value2 != 0 do
    rem(value1, value2)
  end

  def eval(_, _) do
    nil
  end
end
