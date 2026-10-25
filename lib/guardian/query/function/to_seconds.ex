defmodule Guardian.Query.Function.ToSeconds do
  def eval(timestamp) when is_binary(timestamp) do
    case Guardian.Timestamp.parse_seconds(timestamp) do
      {:ok, seconds} -> seconds
      :error -> nil
    end
  end

  def eval(_) do
    nil
  end
end
