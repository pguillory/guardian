defmodule Query.Function.Round do
  def eval(value) when is_number(value) do
    round(value)
  end

  def eval(_) do
    nil
  end
end
