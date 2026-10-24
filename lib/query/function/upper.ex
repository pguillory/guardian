defmodule Query.Function.Upper do
  # Case mapping can lengthen text (ß is SS), so the result is cut to the string cap.
  def eval(value) when is_binary(value) do
    value |> String.upcase() |> Query.Text.cap()
  end

  def eval(_) do
    nil
  end
end
