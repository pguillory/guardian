defmodule Guardian.Query.RegexMemoryTest do
  # The large-value replace helper's cap is the query heap limit: 16 MiB in the test
  # environment (config/config.exs), 256 MiB in production.
  use ExUnit.Case, async: true
  import Guardian.Test.Query, only: [run_sql: 1]

  defp replace(subject, pattern, replacement) do
    {:ok, regex} = Guardian.Query.Regex.compile(pattern)
    Guardian.Query.Regex.replace(regex, subject, replacement)
  end

  test "millions of empty matches on one value are null" do
    # 4 million empty matches. The helper grows to its cap before it is killed.
    s = String.duplicate("a", 4_000_000)
    assert replace(s, "x*", "-") == nil
  end

  test "too many non-empty matches are null too" do
    s = String.duplicate("a", 1_000_000)
    assert replace(s, ".", "") == nil

    # Well under the cap, a large value is replaced as usual.
    assert replace(String.duplicate("a1", 10_000), "[0-9]", "") === String.duplicate("a", 10_000)
  end

  test "a query whose replace has too many matches on a value gives null for it" do
    table = "regex_memory_#{System.unique_integer([:positive])}"

    Guardian.Engine.ingest_events(table, [
      %{"s" => String.duplicate("a", 1_000_000)},
      %{"s" => "b"},
    ])

    assert Enum.sort(run_sql("SELECT replace(s, 'x*', '-') FROM #{table}")) ==
             [[nil], ["-b-"]]

    # The node and its query machinery carry on.
    assert run_sql("SELECT replace(s, 'b', 'c') FROM #{table} WHERE s = 'b'") == [["c"]]
  end
end
