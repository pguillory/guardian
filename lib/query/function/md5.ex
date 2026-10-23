defmodule Query.Function.Md5 do
  def eval(value) when is_binary(value) do
    :crypto.hash(:md5, value)
    |> Base.encode16(case: :lower)
  end

  def eval(_) do
    nil
  end
end
