defmodule Guardian.Query.Function.Interval do
  import Guardian.Query.Numeric, only: [int64?: 1]

  @second 1
  @minute 60
  @hour 60 * 60
  @day 60 * 60 * 24
  @week 60 * 60 * 24 * 7

  def eval(string) when is_binary(string) do
    case to_seconds(string) do
      {:ok, seconds} -> seconds
      :error -> nil
    end
  end

  def eval(_) do
    nil
  end

  @doc """
  Parses a duration such as `"2h 30m"` (units `s`, `m`, `h`, `d`, `w`) into seconds:
  `{:ok, seconds}` or `:error`. Not the SQL `to_seconds` function
  (`Guardian.Query.Function.ToSeconds`).
  """
  def to_seconds(interval) do
    to_seconds(interval, 0)
  end

  defp to_seconds(<<>>, seconds) do
    {:ok, seconds}
  end

  defp to_seconds(" " <> interval, seconds) do
    to_seconds(interval, seconds)
  end

  # A number of more than 19 digits, or a term or running total outside int64, is
  # `:error` (null), so no bignum ever forms (Guardian.Query.Numeric).
  defp to_seconds(interval, seconds) do
    with true <- digits_within_limit?(interval),
         {n, <<unit, interval::binary>>} <- Integer.parse(interval),
         {:ok, unit_seconds} <- unit_seconds(unit),
         term when int64?(term) <- n * unit_seconds,
         total when int64?(total) <- seconds + term do
      to_seconds(interval, total)
    else
      _ -> :error
    end
  end

  defp unit_seconds(?s) do
    {:ok, @second}
  end

  defp unit_seconds(?m) do
    {:ok, @minute}
  end

  defp unit_seconds(?h) do
    {:ok, @hour}
  end

  defp unit_seconds(?d) do
    {:ok, @day}
  end

  defp unit_seconds(?w) do
    {:ok, @week}
  end

  defp unit_seconds(_) do
    :error
  end

  # At most 19 digits after an optional sign, before Integer.parse can build more.
  defp digits_within_limit?(<<sign, rest::binary>>) when sign in [?+, ?-] do
    digits_within_limit?(rest)
  end

  defp digits_within_limit?(string) do
    leading_digits(string, 0) <= 19
  end

  defp leading_digits(<<digit, rest::binary>>, n) when digit in ?0..?9 and n <= 19 do
    leading_digits(rest, n + 1)
  end

  defp leading_digits(_string, n) do
    n
  end

  @doc "Formats seconds as a duration that `to_seconds/1` parses, such as `\"2h30m\"`."
  def from_seconds(0) do
    ""
  end

  def from_seconds(n) do
    cond do
      n >= @week -> "#{div(n, @week)}w" <> from_seconds(rem(n, @week))
      n >= @day -> "#{div(n, @day)}d" <> from_seconds(rem(n, @day))
      n >= @hour -> "#{div(n, @hour)}h" <> from_seconds(rem(n, @hour))
      n >= @minute -> "#{div(n, @minute)}m" <> from_seconds(rem(n, @minute))
      true -> "#{n}s"
    end
  end
end
