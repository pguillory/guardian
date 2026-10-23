defmodule Query.Function.Normalize do
  def eval(value) when is_binary(value) do
    String.normalize(value, :nfc)
  end

  def eval(_) do
    nil
  end

  def eval(value, "NFD") when is_binary(value) do
    String.normalize(value, :nfd)
  end

  def eval(value, "NFC") when is_binary(value) do
    String.normalize(value, :nfc)
  end

  def eval(value, "NFKD") when is_binary(value) do
    String.normalize(value, :nfkd)
  end

  def eval(value, "NFKC") when is_binary(value) do
    String.normalize(value, :nfkc)
  end

  def eval(_, _) do
    nil
  end
end
