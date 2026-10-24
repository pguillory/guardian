defmodule Query.Function.Lower do
  # Case mapping can lengthen text, so the result is cut to the string cap.
  def eval(value) when is_binary(value) do
    value |> String.downcase() |> Query.Text.cap()
  end

  def eval(_) do
    nil
  end
end
