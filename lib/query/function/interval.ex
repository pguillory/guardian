defmodule Query.Function.Interval do
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
  (`Query.Function.ToSeconds`).
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

  defp to_seconds(interval, seconds) do
    case Integer.parse(interval) do
      {n, "s" <> interval} -> to_seconds(interval, seconds + n * @second)
      {n, "m" <> interval} -> to_seconds(interval, seconds + n * @minute)
      {n, "h" <> interval} -> to_seconds(interval, seconds + n * @hour)
      {n, "d" <> interval} -> to_seconds(interval, seconds + n * @day)
      {n, "w" <> interval} -> to_seconds(interval, seconds + n * @week)
      _ -> :error
    end
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
