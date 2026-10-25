defmodule Guardian.Timestamp do
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
  Seconds since 1970-01-01 00:00:00 UTC of a `YYYY-MM-DD HH:MM:SS` timestamp (see
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
  Validates Guardian's UTC `YYYY-MM-DD HH:MM:SS` format, returning `{:ok, string}`
  or `:error`. Only this exact format is accepted: no `T`, `Z`, fractional seconds
  or numeric UTC offsets. Calendar fields must be valid, with years 0000 to 9999.
  """
  def from_string(string) do
    case parse(string) do
      {:ok, _naive_datetime} -> {:ok, string}
      :error -> :error
    end
  end

  # Require the canonical format before ISO parsing, which otherwise accepts alternatives.
  defp parse(match() = string) do
    case NaiveDateTime.from_iso8601(string) do
      {:ok, naive_datetime} ->
        {:ok, naive_datetime}

      _ ->
        :error
    end
  end

  defp parse(_), do: :error
end
