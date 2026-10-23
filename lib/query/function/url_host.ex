defmodule Query.Function.UrlHost do
  def eval(value) when is_binary(value) do
    URI.parse(value).host
  end

  def eval(_) do
    nil
  end
end
