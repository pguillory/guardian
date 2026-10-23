defmodule Query.Function.FormatTimestampTest do
  use Query.EvaluationTestCase, async: true

  test "format_timestamp function" do
    assert eval("format_timestamp('0001-02-03 04:05:06', 'y')") === "1"
    assert eval("format_timestamp('0001-02-03 04:05:06', 'yyyy')") === "0001"
    assert eval("format_timestamp('0001-02-03 04:05:06', 'M')") === "2"
    assert eval("format_timestamp('0001-02-03 04:05:06', 'MM')") === "02"
    assert eval("format_timestamp('0001-02-03 04:05:06', 'MMM')") === "Feb"
    assert eval("format_timestamp('0001-02-03 04:05:06', 'MMMM')") === "February"
    assert eval("format_timestamp('0001-02-03 04:05:06', 'd')") === "3"
    assert eval("format_timestamp('0001-02-03 04:05:06', 'dd')") === "03"
    assert eval("format_timestamp('0001-02-03 04:05:06', 'h')") === "4"
    assert eval("format_timestamp('0001-02-03 04:05:06', 'hh')") === "04"
    assert eval("format_timestamp('0001-02-03 04:05:06', 'm')") === "5"
    assert eval("format_timestamp('0001-02-03 04:05:06', 'mm')") === "05"
    assert eval("format_timestamp('0001-02-03 04:05:06', 's')") === "6"
    assert eval("format_timestamp('0001-02-03 04:05:06', 'ss')") === "06"

    assert eval("format_timestamp('0001-02-03 04:05:06', 'AM')") === "AM"
    assert eval("format_timestamp('0001-02-03 04:05:06', 'PM')") === "AM"
    assert eval("format_timestamp('0001-02-03 04:05:06', 'am')") === "am"
    assert eval("format_timestamp('0001-02-03 04:05:06', 'pm')") === "am"

    assert eval("format_timestamp('0001-02-03 14:05:06', 'AM')") === "PM"
    assert eval("format_timestamp('0001-02-03 14:05:06', 'PM')") === "PM"
    assert eval("format_timestamp('0001-02-03 14:05:06', 'am')") === "pm"
    assert eval("format_timestamp('0001-02-03 14:05:06', 'pm')") === "pm"

    assert eval("format_timestamp('0001-02-03 04:05:06', 'yyyy-MM-dd hh:mm:ss')") ===
             "0001-02-03 04:05:06"
  end
end
