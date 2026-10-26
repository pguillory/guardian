defmodule Guardian.Query.Function.UrlPath do
  def eval(value) when is_binary(value) do
    Guardian.Query.URL.parse(value).path
  end

  def eval(_) do
    nil
  end
end
