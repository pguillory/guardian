defmodule Guardian.Query.Function.DateSub do
  # A result outside years 0000 to 9999 (the timestamp format's range) is null.
  @earliest NaiveDateTime.diff(~N[0000-01-01 00:00:00], ~N[1970-01-01 00:00:00])
  @latest NaiveDateTime.diff(~N[9999-12-31 23:59:59], ~N[1970-01-01 00:00:00])

  def eval(timestamp, interval_seconds)
      when is_binary(timestamp) and is_integer(interval_seconds) do
    with {:ok, timestamp} <- Guardian.Timestamp.from_string(timestamp),
         seconds when seconds >= @earliest and seconds <= @latest <-
           Guardian.Timestamp.to_seconds(timestamp) - interval_seconds do
      Guardian.Timestamp.from_seconds(seconds)
    else
      _ -> nil
    end
  end

  def eval(_left, _right) do
    nil
  end
end
