defmodule Guardian.Query.Function.Sha1 do
  def eval(value) when is_binary(value) do
    :crypto.hash(:sha, value)
    |> Base.encode16(case: :lower)
  end

  def eval(_) do
    nil
  end
end
