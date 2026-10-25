defmodule Guardian.Query.Function.UrlPort do
  # URI.parse/1 doesn't validate, but turning a port of over about 1.26 million
  # digits into an integer hits the VM's system_limit: null, like a port outside
  # 0..65535.
  def eval(value) when is_binary(value) do
    case URI.parse(value).port do
      port when is_integer(port) and port in 0..65_535 -> port
      _ -> nil
    end
  catch
    :error, :system_limit -> nil
  end

  def eval(_) do
    nil
  end
end
