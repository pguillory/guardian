defmodule Guardian.Query.RegexMemoryTest do
  # Changes the global query heap limit, so it must not run beside other tests.
  use ExUnit.Case, async: false
  import Guardian.Test.Query, only: [run_sql: 1]

  defp set_limit(mb) do
    Guardian.Test.Env.put(query_max_heap_mb: mb)
  end

  defp replace(subject, pattern, replacement) do
    {:ok, regex} = Guardian.Query.Regex.compile(pattern)
    Guardian.Query.Regex.replace(regex, subject, replacement)
  end

  test "millions of empty matches on one value are null, under the default heap limit" do
    set_limit(256)

    # 4 million empty matches. The helper grows to its 256 MiB cap in this VM before
    # it is killed, for about a second.
    s = String.duplicate("a", 4_000_000)
    assert replace(s, "x*", "-") == nil
  end

  test "a lower heap limit lowers the cap, for non-empty matches too" do
    set_limit(32)
    s = String.duplicate("a", 1_000_000)
    assert replace(s, ".", "") == nil

    # Well under the cap, a large value is replaced as usual.
    assert replace(String.duplicate("a1", 10_000), "[0-9]", "") === String.duplicate("a", 10_000)
  end

  test "a query whose replace has too many matches on a value gives null for it" do
    set_limit(32)
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
