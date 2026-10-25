defmodule Guardian.Timestamp do
  @earliest NaiveDateTime.diff(~N[0000-01-01 00:00:00], ~N[1970-01-01 00:00:00])
  @latest NaiveDateTime.diff(~N[9999-12-31 23:59:59], ~N[1970-01-01 00:00:00])

  @doc """
  Reads a raw 10-byte date and 8-byte time separated by a space. No other
  separators, digits, calendar fields or UTF-8 bytes are validated.
  """
  def read(<<date::binary-size(10), " ", time::binary-size(8)>>) do
    {:ok, {date, time}}
  end

  def read(_) do
    :error
  end

  @doc """
  Reads the six raw binary fields of the exact `YYYY-MM-DD HH:MM:SS` shape.
  Checks separators and byte lengths only; field contents need not be valid.
  """
  def read_fields(string) do
    with {:ok,
          {<<year::binary-size(4), "-", month::binary-size(2), "-", day::binary-size(2)>>,
           <<hour::binary-size(2), ":", minute::binary-size(2), ":", second::binary-size(2)>>}} <-
           read(string) do
      {:ok, %{year: year, month: month, day: day, hour: hour, minute: minute, second: second}}
    else
      _ -> :error
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

  @doc """
  Shifts a valid canonical UTC timestamp by integer seconds. Returns nil for
  invalid input or a result outside years 0000 to 9999.
  """
  def shift(timestamp, delta) when is_binary(timestamp) and is_integer(delta) do
    with {:ok, naive_datetime} <- parse(timestamp),
         seconds when seconds >= @earliest and seconds <= @latest <-
           NaiveDateTime.diff(naive_datetime, ~N[1970-01-01 00:00:00]) + delta do
      from_seconds(seconds)
    else
      _ -> nil
    end
  end

  def shift(_, _) do
    nil
  end

  # Require the canonical shape before ISO parsing, which otherwise accepts alternatives.
  defp parse(string) do
    with {:ok, _fields} <- read_fields(string),
         {:ok, naive_datetime} <- NaiveDateTime.from_iso8601(string) do
      {:ok, naive_datetime}
    else
      _ -> :error
    end
  end
end
