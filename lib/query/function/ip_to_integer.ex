defmodule Query.Function.IpToInteger do
  def eval(value) when is_binary(value) do
    # Invalid UTF-8 is no address (String.to_charlist would raise on it).
    with true <- String.valid?(value),
         {:ok, {a, b, c, d}} <- :inet.parse_address(String.to_charlist(value)) do
      <<result::32-big>> = <<a, b, c, d>>
      result
    else
      _ -> nil
    end
  end

  def eval(_) do
    nil
  end
end
