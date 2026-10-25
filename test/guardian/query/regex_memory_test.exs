defmodule Guardian.Query.RegexMemoryTest do
  # Changes the global query heap limit, so it must not run beside other tests.
  use ExUnit.Case, async: false
  import Guardian.TestHelpers, only: [run_sql: 1]

  setup do
    previous = Application.fetch_env(:guardian, :query_max_heap_mb)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:guardian, :query_max_heap_mb, value)
        :error -> Application.delete_env(:guardian, :query_max_heap_mb)
      end
    end)
  end

  defp set_limit(mb), do: Application.put_env(:guardian, :query_max_heap_mb, mb)

  defp replace(subject, pattern, replacement) do
    {:ok, regex} = Guardian.Query.Regex.compile(pattern)
    Guardian.Query.Regex.replace(regex, subject, replacement)
  end

  test "the helper's heap cap is the query heap limit, or 256 MiB when that is off" do
    set_limit(0)
    assert Guardian.Query.Regex.helper_heap_mb() == 256
    set_limit(32)
    assert Guardian.Query.Regex.helper_heap_mb() == 32
    Application.delete_env(:guardian, :query_max_heap_mb)
    assert Guardian.Query.Regex.helper_heap_mb() == 256
  end

  test "millions of empty matches on one value are null, with the heap limit off" do
    set_limit(0)

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

  describe "a replace whose caller dies does not run on" do
    # A few seconds of backtracking on a value large enough for the helper, far longer
    # than the tests wait before killing the caller.
    @slow_subject String.duplicate("a", 40_000)

    test "when the caller dies mid-replace" do
      {caller, helper} = start_caller()
      Process.sleep(50)
      assert Process.alive?(helper)
      assert_helper_killed(caller, helper)
    end

    test "when the caller dies as the helper starts" do
      for _ <- 1..20 do
        {caller, helper} = start_caller()
        assert_helper_killed(caller, helper)
      end
    end

    # Starts a caller that runs a slow replace, and returns it and its helper, learned
    # from a trace of the caller's spawns as soon as the helper exists.
    defp start_caller do
      caller =
        spawn(fn ->
          receive do
            :go -> replace(@slow_subject, "a*[^a]", "x")
          end
        end)

      :erlang.trace(caller, true, [:procs])
      send(caller, :go)
      assert_receive {:trace, ^caller, :spawn, helper, _}, 1_000
      {caller, helper}
    end

    defp assert_helper_killed(caller, helper) do
      ref = Process.monitor(helper)
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^ref, :process, ^helper, reason}, 1_000
      assert reason in [:killed, :noproc]
    end
  end
end
