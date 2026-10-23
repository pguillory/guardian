defmodule Query.Function.IpToInteger do
  def eval(value) when is_binary(value) do
    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, {a, b, c, d}} ->
        <<result::32-big>> = <<a, b, c, d>>
        result

      _ ->
        nil
    end
  end

  def eval(_) do
    nil
  end
end
