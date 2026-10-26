defmodule Guardian.Query.Function.UrlFragment do
  def eval(value) when is_binary(value) do
    Guardian.Query.URL.parse(value).fragment
  end

  def eval(_) do
    nil
  end
end
