defmodule Query.Function.IpToInteger do
  # An IPv4 address is at most 15 bytes. :inet also accepts zero-padded parts of any
  # length, but a longer string is null before it becomes a charlist: a charlist costs
  # 16 bytes per byte of input, about 256 MB for a value at the 16 MB event cap.
  @max_bytes 64

  def eval(value) when is_binary(value) and byte_size(value) <= @max_bytes do
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
