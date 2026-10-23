defmodule Query.Function.DateAdd do
  def eval(timestamp, interval_seconds)
      when is_binary(timestamp) and is_integer(interval_seconds) do
    case Timestamp.from_string(timestamp) do
      {:ok, timestamp} ->
        timestamp_seconds = Timestamp.to_seconds(timestamp)
        Timestamp.from_seconds(timestamp_seconds + interval_seconds)

      :error ->
        nil
    end
  end

  def eval(_left, _right) do
    nil
  end
end
