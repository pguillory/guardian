defmodule Query.Function.Mod do
  def eval(value1, value2) when is_integer(value1) and is_integer(value2) do
    rem(value1, value2)
  end

  def eval(_, _) do
    nil
  end
end
