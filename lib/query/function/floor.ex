defmodule Query.Function.Floor do
  def eval(value) when is_number(value) do
    floor(value)
  end

  def eval(_) do
    nil
  end
end
