defmodule Guardian.Query.Function.Sha512 do
  def eval(value) when is_binary(value) do
    :crypto.hash(:sha512, value)
    |> Base.encode16(case: :lower)
  end

  def eval(_) do
    nil
  end
end
