defmodule Rules.ServerTest do
  use ExUnit.Case, async: false
  import RulesTestHelper

  defp s3_server(app_env \\ []) do
    s3 = FakeS3.start()
    on_exit(fn -> FakeS3.stop(s3) end)
    store = FakeS3.store(s3)
    {:ok, _pid} = restart_server(store, app_env)
    {s3, store}
  end

  test "a rejected write saves nothing and lists every new error" do
    table = unique_table("rules_reject")
    {_s3, store} = s3_server()

    assert {:error, {:rejected, [message]}} = Rules.write_rule(table, "a", "SET x = count()")
    assert message == "#{table}/a.gsql line 1: rules cannot use aggregate functions"
    assert Rules.Store.list(store) |> elem(1) |> Enum.reject(&(&1.key == "_write.lock")) == []

    assert {:ok, %{errors: [], unconfirmed: []}} = Rules.write_rule(table, "a", "SET x = 1")
    assert {:error, {:rejected, [conflict]}} = Rules.write_rule(table, "b", "SET x = 2")
    assert conflict =~ "x is defined differently"
    assert Rules.list_rules(table) == {:ok, [%{table: table, name: "a", size: 9}]}
    assert Rules.read_rule(table, "a") == {:ok, "SET x = 1"}
    assert {:error, "no rule file " <> _} = Rules.delete_rule(table, "nope")
    assert {:ok, _} = Rules.delete_rule(table, "a")
    assert Rules.lookup(table) == nil
  end

  test "an invalid stored table fails at boot by default; other tables load" do
    s3 = FakeS3.start()
    on_exit(fn -> FakeS3.stop(s3) end)
    FakeS3.put_object(s3, "bad/a.gsql", "SET x = nosuch(1)")
    FakeS3.put_object(s3, "good/a.gsql", "SET x = 1")

    ExUnit.CaptureLog.capture_log(fn -> {:ok, _} = restart_server(FakeS3.store(s3)) end)
    assert {:invalid, "bad/a.gsql line 1: Invalid function nosuch"} = Rules.lookup("bad")
    assert is_atom(Rules.lookup("good"))
    assert [{:error, _}] = Engine.ingest_events("bad", [%{}])
  end

  test "invalid rules are logged by file, line and kind, never by rule text" do
    s3 = FakeS3.start()
    on_exit(fn -> FakeS3.stop(s3) end)
    marker = "MARKER#{System.unique_integer([:positive])}"
    table = unique_table("rules_log")
    FakeS3.put_object(s3, "#{table}/a.gsql", "SET x = 1 #{marker}")
    FakeS3.put_object(s3, "#{table}/b.gsql", "SET y = 1 + 1 WEEK")
    FakeS3.put_object(s3, "#{table}/c.gsql", <<"SET z = '", 0xFF, "'">>)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        {:ok, _} = restart_server(FakeS3.store(s3))
        Logger.flush()
      end)

    # A file-level error (not UTF-8) has no line.
    assert log =~
             "Rules: 3 invalid: #{table}/a.gsql line 1 (parse); " <>
               "#{table}/b.gsql line 1 (parse); #{table}/c.gsql (encoding)"

    refute log =~ marker
    refute log =~ "WEEK"

    # The message itself, with the rule text it quotes, still reaches the caller.
    assert {:invalid, message} = Rules.lookup(table)
    assert message =~ marker
  end

  test "a misconfigured store refuses startup at once; an unreachable one after retrying" do
    s3 = FakeS3.start()
    on_exit(fn -> FakeS3.stop(s3) end)

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:error, {:rules_store, "store misconfigured (HTTP 403)"}} =
               restart_server(FakeS3.store(%{s3 | secret_access_key: "wrong"}))

      started = System.monotonic_time(:millisecond)

      assert {:error, {:rules_store, "store unreachable (econnrefused)"}} =
               restart_server(FakeS3.store(%{s3 | endpoint: "http://localhost:1"}),
                 rules_boot_retry_ms: 2_500
               )

      assert System.monotonic_time(:millisecond) - started >= 900
    end)
  end

  test "an unreachable store at boot is retried until it answers" do
    s3 = FakeS3.start()
    on_exit(fn -> FakeS3.stop(s3) end)
    FakeS3.put_object(s3, "t/a.gsql", "SET x = 1")
    FakeS3.fault(s3, [{:status, 503}, {:status, 503}])

    ExUnit.CaptureLog.capture_log(fn -> assert {:ok, _} = restart_server(FakeS3.store(s3)) end)
    assert is_atom(Rules.lookup("t"))
  end

  test "a rate-limited store at boot is retried, whether it limits the list or a fetch" do
    s3 = FakeS3.start()
    on_exit(fn -> FakeS3.stop(s3) end)
    FakeS3.put_object(s3, "t/a.gsql", "SET x = 1")
    # The list, then (after a retry) the list again and the fetch.
    FakeS3.fault(s3, [{:status, 429}, nil, {:status, 429}])

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, _} = restart_server(FakeS3.store(s3))
      end)

    # One retry for the list, one for the fetch.
    assert log |> String.split("store unreachable (HTTP 429); retrying") |> length() == 3
    assert is_atom(Rules.lookup("t"))
  end

  test "a rate-limited save or delete saves nothing and releases the lock" do
    {s3, store} = s3_server()
    table = unique_table("rules_429")
    {:ok, _} = Rules.write_rule(table, "a", "SET x = 1")
    module = Rules.lookup(table)

    # With the lock object left released by the first write: the lock create (412),
    # its read, the takeover, the list, then the save or delete; then the release.
    for {fun, method, name} <- [
          {fn -> Rules.write_rule(table, "b", "SET y = 2") end, "PUT", "b"},
          {fn -> Rules.delete_rule(table, "a") end, "DELETE", "a"},
        ] do
      before = length(FakeS3.requests(s3))
      FakeS3.fault(s3, [nil, nil, nil, nil, {:status, 429}])
      assert fun.() == {:error, "store request failed (HTTP 429)"}

      assert [%{method: ^method, path: rule_path}, %{method: "PUT", path: lock_path}] =
               s3 |> FakeS3.requests() |> Enum.drop(before + 4)

      assert String.ends_with?(rule_path, "/#{table}/#{name}.gsql")
      assert String.ends_with?(lock_path, "/" <> Rules.Lock.key())
    end

    assert FakeS3.objects(s3) |> Map.keys() |> Enum.reject(&(&1 =~ "lock")) == [
             "#{table}/a.gsql",
           ]

    {:ok, body, _meta} = Rules.Store.get(store, Rules.Lock.key())
    assert Jason.decode!(body)["state"] == "released"
    assert Rules.lookup(table) == module
    assert {:ok, _} = Rules.write_rule(table, "b", "SET y = 2")
  end

  test "a running node keeps its rules when a reload is rate limited" do
    {s3, _store} = s3_server()
    table = unique_table("rules_429_reload")
    {:ok, _} = Rules.write_rule(table, "a", "SET x = 1")
    module = Rules.lookup(table)
    FakeS3.put_object(s3, "#{table}/a.gsql", "SET x = 2")
    FakeS3.fault(s3, {:status, 429})
    assert {:error, message} = Rules.reload()
    assert message =~ "HTTP 429"
    assert Rules.lookup(table) == module
    assert [{:ok, %{"x" => 1}}] = Engine.ingest_events(table, [%{}])
  end

  test ":sys.get_status shows rule files' ETags, never their text" do
    {s3, _store} = s3_server()
    marker = "MARKER-#{System.unique_integer([:positive])}"
    table = unique_table("rules_status")
    {:ok, _} = Rules.write_rule(table, "a", "SET x = '#{marker}'")
    assert inspect(:sys.get_state(Rules.Server), limit: :infinity) =~ marker

    status = inspect(:sys.get_status(Rules.Server), limit: :infinity, printable_limit: :infinity)
    refute status =~ marker
    assert status =~ FakeS3.objects(s3)["#{table}/a.gsql"].etag

    # With debug logging on, the log holds each message and the state after it. The
    # server's formatted status (the last item) redacts them; the raw debug options
    # `:sys` returns beside it are OTP's own (see docs/architecture/security.md).
    :ok = :sys.log(Rules.Server, true)
    {:ok, _} = Rules.write_rule(table, "b", "SET y = '#{marker}'")
    assert :ok = Rules.reload()
    {:ok, log} = :sys.log(Rules.Server, :get)
    assert inspect(log, limit: :infinity, printable_limit: :infinity) =~ marker

    {:status, _pid, _module, [_pdict, _sys_state, _parent, _debug, formatted]} =
      :sys.get_status(Rules.Server)

    # What a crash report formats: the state, the last message and the debug log.
    report =
      Rules.Server.format_status(%{
        state: :sys.get_state(Rules.Server),
        message: {:"$gen_call", {self(), make_ref()}, {:write, table, "c", marker}},
        log: log,
        reason: :normal,
      })

    :ok = :sys.log(Rules.Server, false)
    formatted = inspect(formatted, limit: :infinity, printable_limit: :infinity)
    assert formatted =~ "Logged events"
    refute formatted =~ marker
    refute inspect(report, limit: :infinity, printable_limit: :infinity) =~ marker
  end

  defmodule CrashingStore do
    @moduledoc false
    # A store whose saves crash the rule server with the source in the exception:
    # in its message, or as the argument of a function clause that does not match.
    def list(_config), do: {:ok, []}
    def get(_config, _key, _etag), do: {:error, :not_found}
    def delete(_config, _key), do: :ok
    def describe(_config), do: "crashing store"

    def put(_config, "_" <> _lock, _body, _condition), do: {:ok, "lock"}
    def put(_config, "t/ok.gsql", _source, _condition), do: {:ok, "saved"}
    def put(_config, "t/clause.gsql", source, _condition), do: clause(source)
    def put(_config, _key, source, _condition), do: raise("cannot save #{source}")

    defp clause(:never), do: :ok
  end

  test "a crash while writing never logs the source: not the message, state or reason" do
    {:ok, _} = restart_server({CrashingStore, nil})
    # A saved rule, in the state and in the debug log the first crash reports. Two
    # crashes only: a third within 5 s would exceed Main's restart intensity.
    saved = "MARKER-#{System.unique_integer([:positive])}"
    :ok = :sys.log(Rules.Server, true)
    assert {:ok, _} = Rules.write_rule("t", "ok", "SET x = '#{saved}'")
    assert inspect(:sys.get_state(Rules.Server), limit: :infinity) =~ saved

    for name <- ["clause", "raise"] do
      marker = "MARKER-#{System.unique_integer([:positive])}"
      pid = Process.whereis(Rules.Server)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Rules.write_rule("t", name, "SET x = '#{marker}'") ==
                   {:error, "the rule server is unavailable; retry"}

          wait_until(fn -> Process.whereis(Rules.Server) not in [nil, pid] end)
          Logger.flush()
        end)

      assert log =~ "Rules.Server"
      assert log =~ "details redacted"
      assert log =~ ":redacted"
      refute log =~ marker
      refute log =~ saved
    end
  end

  test "a broken stored set can be repaired one file at a time; other tables stay writable" do
    {s3, _store} = s3_server()
    table = unique_table("rules_repair")
    FakeS3.put_object(s3, "#{table}/a.gsql", "SET x = nosuch(1)")
    FakeS3.put_object(s3, "#{table}/b.gsql", "SET y = nosuch(2)")
    ExUnit.CaptureLog.capture_log(fn -> assert Rules.reload() == :ok end)
    assert {:invalid, _} = Rules.lookup(table)

    assert {:ok, %{errors: [remaining]}} = Rules.write_rule(table, "a", "-- moved\nSET x = 1")
    assert remaining =~ "#{table}/b.gsql"
    assert {:ok, _} = Rules.write_rule(unique_table("rules_other"), "a", "SET z = 1")
    assert {:ok, %{errors: []}} = Rules.delete_rule(table, "b")
    assert is_atom(Rules.lookup(table))
  end

  test "a running node keeps a table's good rules when the stored copy turns invalid" do
    {s3, _store} = s3_server()
    table = unique_table("rules_keep")
    {:ok, _} = Rules.write_rule(table, "a", "SET x = 1")
    good = Rules.lookup(table)
    FakeS3.put_object(s3, "#{table}/a.gsql", "SET x = ")
    ExUnit.CaptureLog.capture_log(fn -> assert Rules.reload() == :ok end)
    assert Rules.lookup(table) == good
  end

  test "reload publishes nothing unless every changed table compiles" do
    {s3, _store} = s3_server()
    {:ok, _} = Rules.write_rule("t1", "a", "SET x = 1")
    {:ok, _} = Rules.write_rule("t2", "a", "SET x = 1")
    before = Rules.published()

    # Two changed tables and one free name: the second compile has no name.
    :sys.replace_state(Rules.Server, fn state -> %{state | free: Enum.take(state.free, 1)} end)
    FakeS3.put_object(s3, "t1/a.gsql", "SET x = 2")
    FakeS3.put_object(s3, "t2/a.gsql", "SET x = 2")
    assert {:error, "no free rule module names" <> _} = Rules.reload()
    assert Rules.published() == before
    assert [{:ok, %{"x" => 1}}] = Engine.ingest_events("t1", [%{}])
  end

  test "repeated edits stay within the module pool, reclaiming retired modules" do
    {_s3, _store} = s3_server(rules_reclaim_after_ms: 50)
    table = unique_table("rules_pool")
    {:ok, _} = Rules.write_rule(table, "a", "SET x = 0")
    held = Rules.lookup(table)

    for n <- 1..40, do: {:ok, _} = Rules.write_rule(table, "a", "SET x = #{n}")

    Process.sleep(300)
    _ = :sys.get_state(Rules.Server)

    loaded = Enum.count(Rules.Compiler.names(), &(:code.is_loaded(&1) != false))
    assert loaded <= 3
    refute Code.loaded?(held)
    assert Rules.lookup(table).apply(%{}) == %{"x" => 40}
  end

  test "an old module stays callable until it is reclaimed" do
    {_s3, _store} = s3_server()
    table = unique_table("rules_hold")
    {:ok, _} = Rules.write_rule(table, "a", "SET x = 0")
    held = Rules.lookup(table)
    {:ok, _} = Rules.write_rule(table, "a", "SET x = 1")
    {:ok, _} = Rules.delete_rule(table, "a")
    assert held.apply(%{}) == %{"x" => 0}
    assert Rules.lookup(table) == nil
  end

  test "a Rules.Server restart keeps serving the published set and keeps its names reserved" do
    {_s3, _store} = s3_server()
    table = unique_table("rules_restart")
    {:ok, _} = Rules.write_rule(table, "a", "SET x = 1")
    module = Rules.lookup(table)
    pid = Process.whereis(Rules.Server)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, _, _, _}
    assert [{:ok, %{"x" => 1}}] = Engine.ingest_events(table, [%{}])

    wait_until(fn -> Process.whereis(Rules.Server) not in [nil, pid] end)
    state = :sys.get_state(Rules.Server)
    refute module in state.free
    assert Rules.lookup(table) == module
    {:ok, _} = Rules.write_rule(table, "b", "SET y = 2")
    assert [{:ok, %{"x" => 1, "y" => 2}}] = Engine.ingest_events(table, [%{}])
  end

  test "a save whose outcome is unknown reports it and leaves the lock held" do
    {s3, store} = s3_server()
    put_env(:rules_s3_write_deadline_ms, 300)
    table = unique_table("rules_unknown")

    # Faults apply to requests in order: the lock create, the list, then the save.
    FakeS3.fault(s3, [nil, nil, {:delay, 1_000}])

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:error, {:unknown, message}} = Rules.write_rule(table, "a", "SET x = 1")
      assert message =~ "may have been saved"
    end)

    {:ok, body, _meta} = Rules.Store.get(store, Rules.Lock.key())
    assert Jason.decode!(body)["state"] == "held"
  end

  test "after a delete whose outcome is unknown, the next reload unpublishes the rule" do
    {s3, _store} = s3_server()
    put_env(:rules_s3_write_deadline_ms, 300)
    table = unique_table("rules_unknown_delete")
    FakeS3.put_object(s3, "#{table}/a.gsql", "SET x = 1")
    assert :ok = Rules.reload()
    assert is_atom(Rules.lookup(table)) and Rules.lookup(table) != nil

    # The lock create, the list, then the delete, which lands after the deadline.
    FakeS3.fault(s3, [nil, nil, {:delay, 1_000}])

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:error, {:unknown, _message}} = Rules.delete_rule(table, "a")
    end)

    Process.sleep(1_200)
    assert FakeS3.objects(s3) |> Map.keys() |> Enum.reject(&(&1 =~ "lock")) == []
    assert :ok = Rules.reload()
    assert Rules.lookup(table) == nil
  end

  test "a write refuses to save with too little lease left" do
    {_s3, _store} = s3_server()
    put_env(:rules_save_margin_ms, 200_000)

    assert Rules.write_rule(unique_table("rules_margin"), "a", "SET x = 1") ==
             {:error, "the write lock's lease ran short; retry"}
  end

  test "another writer holding the lock makes a write fail as busy" do
    {_s3, store} = s3_server()
    {:ok, _lock} = Rules.Lock.acquire(store, "someone else")

    assert Rules.write_rule(unique_table("rules_busy"), "a", "SET x = 1") ==
             {:error, "another rule write is in progress; retry"}
  end

  test "a rejected write does not hide rules another writer saved from the next reload" do
    {s3, _store} = s3_server()
    table = unique_table("rules_cache")
    FakeS3.put_object(s3, "#{table}/a.gsql", "SET x = 1")

    assert {:error, {:rejected, [_conflict]}} = Rules.write_rule(table, "b", "SET x = 2")
    assert :ok = Rules.reload()
    assert [{:ok, %{"x" => 1}}] = Engine.ingest_events(table, [%{}])
  end

  test "a misnamed rule file makes its table invalid instead of dropping its rules" do
    {s3, store} = s3_server()
    table = unique_table("rules_misnamed")
    assert {:ok, _} = Rules.write_rule(table, "a", "UNSET password")
    FakeS3.put_object(s3, "#{table}/A.gsql", "UNSET password")

    ExUnit.CaptureLog.capture_log(fn -> Rules.reload() end)
    assert [{:ok, event}] = Engine.ingest_events(table, [%{"password" => "p"}])
    refute Map.has_key?(event, "password")

    ExUnit.CaptureLog.capture_log(fn -> {:ok, _} = restart_server(store) end)
    assert {:invalid, _message} = Rules.lookup(table)
    assert [{:error, _}] = Engine.ingest_events(table, [%{"password" => "p"}])
  end

  test "polling picks up changes made to the store directly" do
    {s3, _store} = s3_server(rules_poll_ms: 100)
    table = unique_table("rules_poll")
    FakeS3.put_object(s3, "#{table}/a.gsql", "SET x = 1")
    wait_until(fn -> is_atom(Rules.lookup(table)) and Rules.lookup(table) != nil end)
  end

  test "an oversized stored file is an error without being fetched" do
    {s3, _store} = s3_server()
    table = unique_table("rules_big")
    FakeS3.put_object(s3, "#{table}/a.gsql", String.duplicate(" ", 70_000))
    ExUnit.CaptureLog.capture_log(fn -> Rules.reload() end)
    assert {:invalid, "#{table}/a.gsql: is over 65536 bytes"} == Rules.lookup(table)
    refute Enum.any?(FakeS3.requests(s3), &(&1.method == "GET" and &1.path =~ table))
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        flunk("condition never held")

      true ->
        Process.sleep(50)
        wait_until(fun, tries - 1)
    end
  end
end
