defmodule Timestamp do
  defmacro match(opts \\ []) do
    underscore =
      quote do
        _
      end

    {year, opts} = Keyword.pop_first(opts, :year, underscore)
    {month, opts} = Keyword.pop_first(opts, :month, underscore)
    {day, opts} = Keyword.pop_first(opts, :day, underscore)
    {hour, opts} = Keyword.pop_first(opts, :hour, underscore)
    {minute, opts} = Keyword.pop_first(opts, :minute, underscore)
    {second, opts} = Keyword.pop_first(opts, :second, underscore)
    [] = opts

    quote do
      <<
        unquote(year)::binary-size(4),
        "-",
        unquote(month)::binary-size(2),
        "-",
        unquote(day)::binary-size(2),
        " ",
        unquote(hour)::binary-size(2),
        ":",
        unquote(minute)::binary-size(2),
        ":",
        unquote(second)::binary-size(2)
      >>
    end
  end

  def now do
    NaiveDateTime.utc_now(:second)
    |> NaiveDateTime.to_string()
  end

  def to_seconds(timestamp) do
    NaiveDateTime.from_iso8601!(timestamp)
    |> NaiveDateTime.diff(~N[1970-01-01 00:00:00])
  end

  def from_seconds(seconds) do
    NaiveDateTime.add(~N[1970-01-01 00:00:00], seconds)
    |> NaiveDateTime.to_string()
  end

  def from_string(string) do
    case DateTime.from_iso8601(string) do
      {:ok, datetime} ->
        timestamp =
          datetime
          |> DateTime.to_naive()
          |> NaiveDateTime.truncate(:second)
          |> NaiveDateTime.to_string()

        {:ok, timestamp}

      _ ->
        case NaiveDateTime.from_iso8601(string) do
          {:ok, naive_datetime} ->
            timestamp =
              naive_datetime
              |> NaiveDateTime.truncate(:second)
              |> NaiveDateTime.to_string()

            {:ok, timestamp}

          _ ->
            :error
        end
    end
  end
end
