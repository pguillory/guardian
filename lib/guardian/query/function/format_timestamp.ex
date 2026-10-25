defmodule Guardian.Query.Function.FormatTimestamp do
  alias Guardian.Timestamp

  # Raw fields are intentional: only a requested month/hour name checks its range.
  def eval(timestamp, format) when is_binary(format) do
    case Timestamp.read_fields(timestamp) do
      {:ok, fields} -> eval_format(format, fields, "")
      :error -> nil
    end
  end

  def eval(_, _) do
    nil
  end

  defp eval_format("yyyy" <> format, fields, output) do
    year = fields.year
    eval_format(format, fields, [output | year])
  end

  defp eval_format("y" <> format, fields, output) do
    year = fields.year
    year = String.trim_leading(year, "0")
    eval_format(format, fields, [output | year])
  end

  defp eval_format("MMMM" <> format, fields, output) do
    append_name(month_name(fields.month), format, fields, output)
  end

  defp eval_format("MMM" <> format, fields, output) do
    append_name(month_abbreviation(fields.month), format, fields, output)
  end

  defp eval_format("MM" <> format, fields, output) do
    month = fields.month
    eval_format(format, fields, [output | month])
  end

  defp eval_format("M" <> format, fields, output) do
    month = fields.month
    month = String.trim_leading(month, "0")
    eval_format(format, fields, [output | month])
  end

  defp eval_format("dd" <> format, fields, output) do
    day = fields.day
    eval_format(format, fields, [output | day])
  end

  defp eval_format("d" <> format, fields, output) do
    day = fields.day
    day = String.trim_leading(day, "0")
    eval_format(format, fields, [output | day])
  end

  defp eval_format("hh" <> format, fields, output) do
    hour = fields.hour
    eval_format(format, fields, [output | hour])
  end

  defp eval_format("h" <> format, fields, output) do
    hour = fields.hour
    hour = String.trim_leading(hour, "0")
    eval_format(format, fields, [output | hour])
  end

  defp eval_format("mm" <> format, fields, output) do
    minute = fields.minute
    eval_format(format, fields, [output | minute])
  end

  defp eval_format("m" <> format, fields, output) do
    minute = fields.minute
    minute = String.trim_leading(minute, "0")
    eval_format(format, fields, [output | minute])
  end

  defp eval_format("ss" <> format, fields, output) do
    second = fields.second
    eval_format(format, fields, [output | second])
  end

  defp eval_format("s" <> format, fields, output) do
    second = fields.second
    second = String.trim_leading(second, "0")
    eval_format(format, fields, [output | second])
  end

  defp eval_format("AM" <> format, fields, output) do
    append_name(am_pm_upper(fields.hour), format, fields, output)
  end

  defp eval_format("PM" <> format, fields, output) do
    append_name(am_pm_upper(fields.hour), format, fields, output)
  end

  defp eval_format("am" <> format, fields, output) do
    append_name(am_pm_lower(fields.hour), format, fields, output)
  end

  defp eval_format("pm" <> format, fields, output) do
    append_name(am_pm_lower(fields.hour), format, fields, output)
  end

  defp eval_format(<<c::binary-size(1), format::binary>>, fields, output) do
    eval_format(format, fields, [output | c])
  end

  # A long format can name more than the string cap holds.
  defp eval_format("", _fields, output) do
    output |> IO.iodata_to_binary() |> Guardian.Query.Text.cap()
  end

  # Raw fields are unvalidated: an out-of-range month or hour has no name, so no result.
  defp append_name(nil, _format, _fields, _output) do
    nil
  end

  defp append_name(name, format, fields, output) do
    eval_format(format, fields, [output | name])
  end

  defp month_abbreviation(month) do
    case month do
      "01" -> "Jan"
      "02" -> "Feb"
      "03" -> "Mar"
      "04" -> "Apr"
      "05" -> "May"
      "06" -> "Jun"
      "07" -> "Jul"
      "08" -> "Aug"
      "09" -> "Sep"
      "10" -> "Oct"
      "11" -> "Nov"
      "12" -> "Dec"
      _ -> nil
    end
  end

  defp month_name(month) do
    case month do
      "01" -> "January"
      "02" -> "February"
      "03" -> "March"
      "04" -> "April"
      "05" -> "May"
      "06" -> "June"
      "07" -> "July"
      "08" -> "August"
      "09" -> "September"
      "10" -> "October"
      "11" -> "November"
      "12" -> "December"
      _ -> nil
    end
  end

  defp am_pm_upper(hour) do
    case hour do
      "00" -> "AM"
      "01" -> "AM"
      "02" -> "AM"
      "03" -> "AM"
      "04" -> "AM"
      "05" -> "AM"
      "06" -> "AM"
      "07" -> "AM"
      "08" -> "AM"
      "09" -> "AM"
      "10" -> "AM"
      "11" -> "AM"
      "12" -> "PM"
      "13" -> "PM"
      "14" -> "PM"
      "15" -> "PM"
      "16" -> "PM"
      "17" -> "PM"
      "18" -> "PM"
      "19" -> "PM"
      "20" -> "PM"
      "21" -> "PM"
      "22" -> "PM"
      "23" -> "PM"
      _ -> nil
    end
  end

  defp am_pm_lower(hour) do
    case hour do
      "00" -> "am"
      "01" -> "am"
      "02" -> "am"
      "03" -> "am"
      "04" -> "am"
      "05" -> "am"
      "06" -> "am"
      "07" -> "am"
      "08" -> "am"
      "09" -> "am"
      "10" -> "am"
      "11" -> "am"
      "12" -> "pm"
      "13" -> "pm"
      "14" -> "pm"
      "15" -> "pm"
      "16" -> "pm"
      "17" -> "pm"
      "18" -> "pm"
      "19" -> "pm"
      "20" -> "pm"
      "21" -> "pm"
      "22" -> "pm"
      "23" -> "pm"
      _ -> nil
    end
  end
end
