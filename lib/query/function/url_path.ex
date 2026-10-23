defmodule Query.Function.UrlPath do
  def eval(value) when is_binary(value) do
    URI.parse(value).path
  end

  def eval(_) do
    nil
  end
end
