defmodule Query.Function.UrlScheme do
  def eval(value) when is_binary(value) do
    URI.parse(value).scheme
  end

  def eval(_) do
    nil
  end
end
