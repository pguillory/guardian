defmodule Query.Function.FormatTimestamp do
  require Timestamp

  # A field outside its range (month 13, hour 25: Timestamp.match/0 checks only the
  # shape) has no name to format: null.
  def eval(Timestamp.match() = timestamp, format) when is_binary(format) do
    eval_format(format, timestamp, "")
  rescue
    CaseClauseError -> nil
  end

  def eval(_, _) do
    nil
  end

  defp eval_format("yyyy" <> format, timestamp, output) do
    Timestamp.match(year: year) = timestamp
    eval_format(format, timestamp, [output | year])
  end

  defp eval_format("y" <> format, timestamp, output) do
    Timestamp.match(year: year) = timestamp
    year = String.trim_leading(year, "0")
    eval_format(format, timestamp, [output | year])
  end

  defp eval_format("MMMM" <> format, timestamp, output) do
    Timestamp.match(month: month) = timestamp
    month = month_name(month)
    eval_format(format, timestamp, [output | month])
  end

  defp eval_format("MMM" <> format, timestamp, output) do
    Timestamp.match(month: month) = timestamp
    month = month_abbreviation(month)
    eval_format(format, timestamp, [output | month])
  end

  defp eval_format("MM" <> format, timestamp, output) do
    Timestamp.match(month: month) = timestamp
    eval_format(format, timestamp, [output | month])
  end

  defp eval_format("M" <> format, timestamp, output) do
    Timestamp.match(month: month) = timestamp
    month = String.trim_leading(month, "0")
    eval_format(format, timestamp, [output | month])
  end

  defp eval_format("dd" <> format, timestamp, output) do
    Timestamp.match(day: day) = timestamp
    eval_format(format, timestamp, [output | day])
  end

  defp eval_format("d" <> format, timestamp, output) do
    Timestamp.match(day: day) = timestamp
    day = String.trim_leading(day, "0")
    eval_format(format, timestamp, [output | day])
  end

  defp eval_format("hh" <> format, timestamp, output) do
    Timestamp.match(hour: hour) = timestamp
    eval_format(format, timestamp, [output | hour])
  end

  defp eval_format("h" <> format, timestamp, output) do
    Timestamp.match(hour: hour) = timestamp
    hour = String.trim_leading(hour, "0")
    eval_format(format, timestamp, [output | hour])
  end

  defp eval_format("mm" <> format, timestamp, output) do
    Timestamp.match(minute: minute) = timestamp
    eval_format(format, timestamp, [output | minute])
  end

  defp eval_format("m" <> format, timestamp, output) do
    Timestamp.match(minute: minute) = timestamp
    minute = String.trim_leading(minute, "0")
    eval_format(format, timestamp, [output | minute])
  end

  defp eval_format("ss" <> format, timestamp, output) do
    Timestamp.match(second: second) = timestamp
    eval_format(format, timestamp, [output | second])
  end

  defp eval_format("s" <> format, timestamp, output) do
    Timestamp.match(second: second) = timestamp
    second = String.trim_leading(second, "0")
    eval_format(format, timestamp, [output | second])
  end

  defp eval_format("AM" <> format, timestamp, output) do
    Timestamp.match(hour: hour) = timestamp
    eval_format(format, timestamp, [output | am_pm_upper(hour)])
  end

  defp eval_format("PM" <> format, timestamp, output) do
    Timestamp.match(hour: hour) = timestamp
    eval_format(format, timestamp, [output | am_pm_upper(hour)])
  end

  defp eval_format("am" <> format, timestamp, output) do
    Timestamp.match(hour: hour) = timestamp
    eval_format(format, timestamp, [output | am_pm_lower(hour)])
  end

  defp eval_format("pm" <> format, timestamp, output) do
    Timestamp.match(hour: hour) = timestamp
    eval_format(format, timestamp, [output | am_pm_lower(hour)])
  end

  defp eval_format(<<c::binary-size(1), format::binary>>, timestamp, output) do
    eval_format(format, timestamp, [output | c])
  end

  defp eval_format("", _timestamp, output) do
    IO.iodata_to_binary(output)
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
    end
  end
end
