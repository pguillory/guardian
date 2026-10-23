defmodule Query.Function.UrlPort do
  # A port outside 0..65535 is no port: null.
  def eval(value) when is_binary(value) do
    case URI.parse(value).port do
      port when is_integer(port) and port in 0..65_535 -> port
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def eval(_) do
    nil
  end
end
