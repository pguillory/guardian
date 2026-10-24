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

  @doc """
  Seconds since 1970-01-01 00:00:00 UTC of an ISO 8601 date and time (see
  `from_string/1`). Raises `ArgumentError` on a string it can't read.
  """
  def to_seconds(timestamp) do
    case parse(timestamp) do
      {:ok, naive_datetime} -> NaiveDateTime.diff(naive_datetime, ~N[1970-01-01 00:00:00])
      :error -> raise ArgumentError, "not a timestamp"
    end
  end

  def from_seconds(seconds) do
    NaiveDateTime.add(~N[1970-01-01 00:00:00], seconds)
    |> NaiveDateTime.to_string()
  end

  @doc """
  An ISO 8601 date and time as Guardian's UTC `YYYY-MM-DD HH:MM:SS`, or `:error`.
  The date and time may be split by `T` or a space and may carry fractional seconds
  (dropped). A UTC offset (`Z`, `+02:00`, `+0200` or `+02`) is applied, so
  `19:35:00+02:00` is `17:35:00`; without one the time is taken as UTC already. A
  string with an offset Elixir can't read, or whose UTC time falls outside years
  0000 to 9999, is `:error`.
  """
  def from_string(string) do
    case parse(string) do
      {:ok, naive_datetime} ->
        timestamp =
          naive_datetime
          |> NaiveDateTime.truncate(:second)
          |> NaiveDateTime.to_string()

        {:ok, timestamp}

      :error ->
        :error
    end
  end

  defp parse(string) when is_binary(string) do
    result =
      case DateTime.from_iso8601(string) do
        {:ok, datetime, _offset} -> {:ok, DateTime.to_naive(datetime)}
        {:error, :missing_offset} -> NaiveDateTime.from_iso8601(string)
        {:error, _} -> :error
      end

    case result do
      {:ok, %NaiveDateTime{year: year} = naive_datetime} when year in 0..9999 ->
        {:ok, naive_datetime}

      _ ->
        :error
    end
  end

  defp parse(_), do: :error
end
