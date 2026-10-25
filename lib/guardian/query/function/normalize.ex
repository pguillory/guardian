defmodule Guardian.Query.Function.Normalize do
  # Normalization can lengthen text (NFD of é is three bytes from two), so the result
  # is cut to the string cap.
  @forms %{"NFC" => :nfc, "NFD" => :nfd, "NFKC" => :nfkc, "NFKD" => :nfkd}

  def eval(value) do
    eval(value, "NFC")
  end

  def eval(value, form) when is_binary(value) and is_map_key(@forms, form) do
    value |> String.normalize(Map.fetch!(@forms, form)) |> Guardian.Query.Text.cap()
  end

  def eval(_, _) do
    nil
  end
end
