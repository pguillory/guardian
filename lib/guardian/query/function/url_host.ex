defmodule Guardian.Query.Function.UrlHost do
  def eval(value) when is_binary(value) do
    Guardian.Query.URL.parse(value).host
  end

  def eval(_) do
    nil
  end
end
