defmodule Query.Function.UrlPort do
  def eval(value) when is_binary(value) do
    URI.parse(value).port
  end

  def eval(_) do
    nil
  end
end
