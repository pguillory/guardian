defmodule Query.Function.UrlFragment do
  def eval(value) when is_binary(value) do
    URI.parse(value).fragment
  end

  def eval(_) do
    nil
  end
end
