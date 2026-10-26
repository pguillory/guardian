defmodule Guardian.Query.Function.UrlPort do
  # Null for a port outside 0..65535, or one Guardian.Query.URL doesn't convert.
  def eval(value) when is_binary(value) do
    case Guardian.Query.URL.parse(value) do
      %URI{port: port} when is_integer(port) and port in 0..65_535 -> port
      _ -> nil
    end
  end

  def eval(_) do
    nil
  end
end
