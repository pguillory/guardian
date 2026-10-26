defmodule Guardian.Query.Function.UrlScheme do
  def eval(value) when is_binary(value) do
    Guardian.Query.URL.parse(value).scheme
  end

  def eval(_) do
    nil
  end
end
