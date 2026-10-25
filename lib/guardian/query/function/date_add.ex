defmodule Guardian.Query.Function.DateAdd do
  def eval(timestamp, interval_seconds)
      when is_binary(timestamp) and is_integer(interval_seconds) do
    Guardian.Timestamp.shift(timestamp, interval_seconds)
  end

  def eval(_left, _right) do
    nil
  end
end
