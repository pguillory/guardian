defmodule Guardian.Rules.ServerTest do
  # Not async: restarts the node-wide Rules.Server and sets the application env.
  use ExUnit.Case, async: false
  import Guardian.Rules.Server
  import Guardian.Test.Rules

  test "the default save margin exceeds the S3 write deadline" do
    # Guardian.Test.Env records prior values (or absence) and restores them on exit. Delete
    # these throwaway placeholders immediately so the defaults apply.
    Guardian.Test.Env.put(rules_save_margin_ms: 1, object_store_s3_write_deadline_ms: 1)
    Application.delete_env(:guardian, :rules_save_margin_ms)
    Application.delete_env(:guardian, :object_store_s3_write_deadline_ms)

    assert save_margin_ms() > Guardian.ObjectStore.S3.write_deadline_ms()
  end

  defp s3_server(app_env \\ []) do
    s3 = Guardian.Test.FakeS3.start()
    on_exit(fn -> Guardian.Test.FakeS3.stop(s3) end)
    store = Guardian.Test.FakeS3.store(s3)
    {:ok, _pid} = restart_server(store, app_env)
    {s3, store}
  end

  test "nested restarts restore the previous env and running server on exit" do
    {_s3, original_store} = s3_server(rules_reclaim_after_ms: 120_000)
    table = unique_table("rules_restore")
    assert {:ok, _} = Guardian.Rules.write_rule(table, "original", "SET x = 1")
    assert Application.fetch_env(:guardian, :rules_test_helper_unset) == :error

    temporary_s3 = Guardian.Test.FakeS3.start()
    on_exit(fn -> Guardian.Test.FakeS3.stop(temporary_s3) end)
    temporary_store = Guardian.Test.FakeS3.store(temporary_s3)

    # Registered first, so this observes the real exit restoration, including the
    # restarted server loading the original store's rules.
    on_exit(fn ->
      assert Application.fetch_env(:guardian, :rules_store) == {:ok, original_store}
      assert Application.fetch_env(:guardian, :rules_reclaim_after_ms) == {:ok, 120_000}
      assert Application.fetch_env(:guardian, :rules_test_helper_unset) == :error
      assert server = Process.whereis(Guardian.Rules.Server)
      assert Process.alive?(server)
      assert Guardian.Rules.lookup(table) != nil
      assert Guardian.Rules.read_rule(table, "original") == {:ok, "SET x = 1"}
    end)

    assert {:ok, _} =
             restart_server(temporary_store,
               rules_reclaim_after_ms: 180_000,
               rules_test_helper_unset: :temporary
             )

    assert Guardian.Rules.lookup(table) == nil

    on_exit(fn ->
      assert Application.fetch_env(:guardian, :rules_store) == {:ok, temporary_store}
      assert Application.fetch_env(:guardian, :rules_reclaim_after_ms) == {:ok, 180_000}
      assert Application.fetch_env(:guardian, :rules_test_helper_unset) == {:ok, :temporary}
      assert server = Process.whereis(Guardian.Rules.Server)
      assert Process.alive?(server)
    end)

    assert {:ok, _} = restart_server(nil, rules_reclaim_after_ms: 240_000)
    assert Application.fetch_env(:guardian, :rules_store) == {:ok, temporary_store}
    assert Application.fetch_env(:guardian, :rules_reclaim_after_ms) == {:ok, 240_000}
  end

  test "a rejected write saves nothing and lists every new error" do
    table = unique_table("rules_reject")
    {_s3, store} = s3_server()

    assert {:error, {:rejected, [message]}} =
             Guardian.Rules.write_rule(table, "a", "SET x = count()")

    assert message == "#{table}/a.gsql line 1: rules cannot use aggregate functions"

    assert Guardian.ObjectStore.list(store) |> elem(1) |> Enum.reject(&(&1.key == "_write.lock")) ==
             []

    assert {:ok, %{errors: [], unconfirmed: []}} =
             Guardian.Rules.write_rule(table, "a", "SET x = 1")

    assert {:error, {:rejected, [conflict]}} = Guardian.Rules.write_rule(table, "b", "SET x = 2")
    assert conflict =~ "x is defined differently"
    assert Guardian.Rules.list_rules(table) == {:ok, [%{table: table, name: "a", size: 9}]}
    assert Guardian.Rules.read_rule(table, "a") == {:ok, "SET x = 1"}
    assert {:error, "no rule file " <> _} = Guardian.Rules.delete_rule(table, "nope")
    assert {:ok, _} = Guardian.Rules.delete_rule(table, "a")
    assert Guardian.Rules.lookup(table) == nil
  end

  test "a local folder is read like a bucket: stray files are ignored, misplaced rules are errors" do
    dir = Path.join(System.tmp_dir!(), "rules_stray_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    nested = unique_table("rules_nested")
    good = unique_table("rules_good")

    for {key, body} <- [
          {"x.gsql", "SET x = 1"},
          {"#{nested}/sub/a.gsql", "SET x = 1"},
          {"#{nested}/a.gsql", "SET x = 1"},
          {"#{good}/a.gsql", "SET x = 1"},
          {"#{good}/notes.txt", "not a rule"},
          {"README", "not a rule"},
        ] do
      path = Path.join(dir, key)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, body)
    end

    {:ok, store} = Guardian.ObjectStore.Local.new(dir)
    {:ok, _} = restart_server(store)

    # The nested file makes its table invalid; the root file names no table.
    assert {:invalid, _} = Guardian.Rules.lookup(nested)
    assert (module = Guardian.Rules.lookup(good)) != nil and is_atom(module)
    assert Guardian.Rules.list_rules(good) == {:ok, [%{table: good, name: "a", size: 9}]}

    # Existing errors do not block a write, which reports them.
    assert {:ok, %{errors: errors}} = Guardian.Rules.write_rule(good, "b", "SET y = 2")
    assert Enum.any?(errors, &String.starts_with?(&1, "x.gsql"))
    assert Enum.any?(errors, &String.starts_with?(&1, "#{nested}/sub/a.gsql"))
    assert Guardian.Rules.lookup(good) not in [nil, module]
  end

  test "an invalid stored table fails at boot by default; other tables load" do
    s3 = Guardian.Test.FakeS3.start()
    on_exit(fn -> Guardian.Test.FakeS3.stop(s3) end)
    Guardian.Test.FakeS3.put_object(s3, "bad/a.gsql", "SET x = nosuch(1)")
    Guardian.Test.FakeS3.put_object(s3, "good/a.gsql", "SET x = 1")

    {:ok, _} = restart_server(Guardian.Test.FakeS3.store(s3))

    assert {:invalid, "bad/a.gsql line 1: Invalid function nosuch"} = Guardian.Rules.lookup("bad")
    assert is_atom(Guardian.Rules.lookup("good"))
    assert [{:error, _}] = Guardian.Engine.ingest_events("bad", [%{}])
  end

  test "invalid counter writes save nothing and valid counters execute through generated modules" do
    # Not about budgets: a larger one keeps healthy counter calls from timing out under load.
    Guardian.Test.Counters.Budget.relax()
    table = unique_table("counter_reject")
    {_s3, store} = s3_server()

    for {word, source} <- [
          {:counter_window, "TRACK c = count() BY secret_group LAST '0s'"},
          {:counter_target, "LOOKUP x = c BY secret_group"},
        ] do
      assert {:error, {:rejected, [message]}} =
               Guardian.Rules.write_rule(table, "a", "\n" <> source)

      assert message =~ "#{table}/a.gsql line 2:"
      refute message =~ "secret_group"

      assert [%{kind: ^word}] =
               Guardian.Rules.RuleSet.validate(%{"#{table}/a.gsql" => source}).errors
    end

    assert Guardian.ObjectStore.list(store) |> elem(1) |> Enum.reject(&(&1.key == "_write.lock")) ==
             []

    assert Guardian.Rules.lookup(table) == nil

    assert {:ok, _} =
             Guardian.Rules.write_rule(
               table,
               "a",
               "TRACK c = count() LAST '1h'; LOOKUP prior = c"
             )

    module = Guardian.Rules.lookup(table)
    assert module.apply(%{}) == %{"c" => 1, "prior" => 0}
    assert [{:ok, %{"c" => 2, "prior" => 1}}] = Guardian.Engine.ingest_events(table, [%{}])
  end

  test "invalid counter rules at boot invalidate only their table" do
    s3 = Guardian.Test.FakeS3.start()
    on_exit(fn -> Guardian.Test.FakeS3.stop(s3) end)
    table = unique_table("counter_boot")
    good = unique_table("counter_boot_good")

    Guardian.Test.FakeS3.put_object(
      s3,
      "#{table}/a.gsql",
      "TRACK c = count() BY secret_group LAST '0s'"
    )

    Guardian.Test.FakeS3.put_object(s3, "#{good}/a.gsql", "SET x = 1")

    {:ok, _} = restart_server(Guardian.Test.FakeS3.store(s3))

    assert {:invalid, _} = Guardian.Rules.lookup(table)
    assert [{:error, _}] = Guardian.Engine.ingest_events(table, [%{}])
    assert [{:ok, %{"x" => 1}}] = Guardian.Engine.ingest_events(good, [%{}])
  end

  test "a misconfigured store refuses startup at once" do
    s3 = Guardian.Test.FakeS3.start()
    on_exit(fn -> Guardian.Test.FakeS3.stop(s3) end)
    previous_store = Application.fetch_env(:guardian, :rules_store)

    on_exit(fn ->
      assert Application.fetch_env(:guardian, :rules_store) == previous_store
      assert server = Process.whereis(Guardian.Rules.Server)
      assert Process.alive?(server)
    end)

    assert {:error, {:rules_store, "store misconfigured (HTTP 403)"}} =
             restart_server(Guardian.Test.FakeS3.store(%{s3 | secret_access_key: "wrong"}))
  end

  @tag :lifecycle
  test "an unreachable store at boot is retried until it answers" do
    s3 = Guardian.Test.FakeS3.start()
    on_exit(fn -> Guardian.Test.FakeS3.stop(s3) end)
    Guardian.Test.FakeS3.put_object(s3, "t/a.gsql", "SET x = 1")
    Guardian.Test.FakeS3.fault(s3, [{:status, 503}, {:status, 503}])

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, _} = restart_server(Guardian.Test.FakeS3.store(s3))
      end)

    assert log |> String.split("store unreachable (HTTP 503); retrying") |> length() == 3
    assert is_atom(Guardian.Rules.lookup("t"))
  end

  @tag :lifecycle
  test "a rate-limited store at boot is retried, whether it limits the list or a fetch" do
    s3 = Guardian.Test.FakeS3.start()
    on_exit(fn -> Guardian.Test.FakeS3.stop(s3) end)
    Guardian.Test.FakeS3.put_object(s3, "t/a.gsql", "SET x = 1")
    # The list, then (after a retry) the list again and the fetch.
    Guardian.Test.FakeS3.fault(s3, [{:status, 429}, nil, {:status, 429}])

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, _} = restart_server(Guardian.Test.FakeS3.store(s3))
      end)

    # One retry for the list, one for the fetch.
    assert log |> String.split("store unreachable (HTTP 429); retrying") |> length() == 3
    assert is_atom(Guardian.Rules.lookup("t"))
  end

  test "a rate-limited save or delete saves nothing and releases the lock" do
    {s3, store} = s3_server()
    table = unique_table("rules_429")
    {:ok, _} = Guardian.Rules.write_rule(table, "a", "SET x = 1")
    module = Guardian.Rules.lookup(table)

    # With the lock object left released by the first write: the lock create (412),
    # its read, the takeover, the list, then the save or delete; then the release.
    for {fun, method, name} <- [
          {fn -> Guardian.Rules.write_rule(table, "b", "SET y = 2") end, "PUT", "b"},
          {fn -> Guardian.Rules.delete_rule(table, "a") end, "DELETE", "a"},
        ] do
      before = length(Guardian.Test.FakeS3.requests(s3))
      Guardian.Test.FakeS3.fault(s3, [nil, nil, nil, nil, {:status, 429}])
      assert fun.() == {:error, "store request failed (HTTP 429)"}

      assert [%{method: ^method, path: rule_path}, %{method: "PUT", path: lock_path}] =
               s3 |> Guardian.Test.FakeS3.requests() |> Enum.drop(before + 4)

      assert String.ends_with?(rule_path, "/#{table}/#{name}.gsql")
      assert String.ends_with?(lock_path, "/" <> lock_key())
    end

    assert Guardian.Test.FakeS3.objects(s3) |> Map.keys() |> Enum.reject(&(&1 =~ "lock")) == [
             "#{table}/a.gsql",
           ]

    {:ok, body, _meta} = Guardian.ObjectStore.get(store, lock_key())
    assert Jason.decode!(body)["state"] == "released"
    assert Guardian.Rules.lookup(table) == module
    assert {:ok, _} = Guardian.Rules.write_rule(table, "b", "SET y = 2")
  end

  test "a running node keeps its rules when a reload is rate limited" do
    {s3, _store} = s3_server()
    table = unique_table("rules_429_reload")
    {:ok, _} = Guardian.Rules.write_rule(table, "a", "SET x = 1")
    module = Guardian.Rules.lookup(table)
    Guardian.Test.FakeS3.put_object(s3, "#{table}/a.gsql", "SET x = 2")
    Guardian.Test.FakeS3.fault(s3, {:status, 429})
    assert {:error, message} = Guardian.Rules.reload()
    assert message =~ "HTTP 429"
    assert Guardian.Rules.lookup(table) == module
    assert [{:ok, %{"x" => 1}}] = Guardian.Engine.ingest_events(table, [%{}])
  end

  test "a broken stored set can be repaired one file at a time; other tables stay writable" do
    {s3, _store} = s3_server()
    table = unique_table("rules_repair")
    Guardian.Test.FakeS3.put_object(s3, "#{table}/a.gsql", "SET x = nosuch(1)")
    Guardian.Test.FakeS3.put_object(s3, "#{table}/b.gsql", "SET y = nosuch(2)")
    assert Guardian.Rules.reload() == :ok
    assert {:invalid, _} = Guardian.Rules.lookup(table)

    assert {:ok, %{errors: [remaining]}} =
             Guardian.Rules.write_rule(table, "a", "-- moved\nSET x = 1")

    assert remaining =~ "#{table}/b.gsql"
    assert {:ok, _} = Guardian.Rules.write_rule(unique_table("rules_other"), "a", "SET z = 1")
    assert {:ok, %{errors: []}} = Guardian.Rules.delete_rule(table, "b")
    assert is_atom(Guardian.Rules.lookup(table))
  end

  test "a reload that finds a table's stored copy invalid fails its events, like boot" do
    {s3, store} = s3_server()
    table = unique_table("rules_turned_invalid")
    other = unique_table("rules_still_valid")
    {:ok, _} = Guardian.Rules.write_rule(table, "a", "SET x = 1")
    {:ok, _} = Guardian.Rules.write_rule(other, "a", "SET x = 1")
    Guardian.Test.FakeS3.put_object(s3, "#{table}/a.gsql", "SET x = ")
    assert Guardian.Rules.reload() == :ok
    assert {:invalid, reloaded} = Guardian.Rules.lookup(table)

    assert [{:error, message}] = Guardian.Engine.ingest_events(table, [%{}])
    assert message =~ "rules for #{table} are invalid"

    assert [{:ok, %{"x" => 1}}] = Guardian.Engine.ingest_events(other, [%{}])
    assert {:ok, [_]} = Guardian.Rules.list_rules(table)

    {:ok, _} = restart_server(store)
    assert Guardian.Rules.lookup(table) == {:invalid, reloaded}
  end

  test "a published module carries its plan's table and hash, including regex and scalar literals" do
    {_s3, _store} = s3_server()
    table = unique_table("rules_metadata")

    source =
      "SET x = message RLIKE '^secret$'; SET y = CASE WHEN x THEN 'yes' ELSE 'no' END; UNSET password"

    assert {:ok, _} = Guardian.Rules.write_rule(table, "a", source)
    module = Guardian.Rules.lookup(table)

    assert {:ok, expected} =
             Guardian.Rules.RuleSet.validate(%{"#{table}/a.gsql" => source}).tables[table]

    assert module.hash() == expected.hash
    assert module.table() == expected.table

    assert module.apply(%{"message" => "secret", "password" => "hide"}) ==
             %{"message" => "secret", "x" => true, "y" => "yes"}
  end

  test "writing an unrelated table activates a broken stored table as invalid and reports it once" do
    {s3, _store} = s3_server()
    table = unique_table("rules_broken")
    other = unique_table("rules_unrelated")
    assert {:ok, _} = Guardian.Rules.write_rule(table, "a", "SET x = 1; UNSET password")
    Guardian.Test.FakeS3.put_object(s3, "#{table}/a.gsql", "SET x = nosuch(1)")

    assert {:ok, %{errors: [error], unconfirmed: []}} =
             Guardian.Rules.write_rule(other, "a", "SET x = 2")

    assert error == "#{table}/a.gsql line 1: Invalid function nosuch"

    assert Guardian.Rules.lookup(table) ==
             {:invalid, "#{table}/a.gsql line 1: Invalid function nosuch"}

    assert [{:error, _}] = Guardian.Engine.ingest_events(table, [%{"password" => "hide"}])
    assert [{:ok, %{"x" => 2}}] = Guardian.Engine.ingest_events(other, [%{}])
  end

  test "reload publishes nothing unless every changed table compiles" do
    {s3, _store} = s3_server()
    {:ok, _} = Guardian.Rules.write_rule("t1", "a", "SET x = 1")
    {:ok, _} = Guardian.Rules.write_rule("t2", "a", "SET x = 1")
    before = Guardian.Rules.published()
    hashes = Map.new(before, fn {table, module} -> {table, module.hash()} end)

    # Two changed tables and one free name: the second compile has no name.
    :sys.replace_state(Guardian.Rules.Server, fn state ->
      %{state | publisher: %{state.publisher | free: Enum.take(state.publisher.free, 1)}}
    end)

    publisher = :sys.get_state(Guardian.Rules.Server).publisher
    [free] = publisher.free
    Guardian.Test.FakeS3.put_object(s3, "t1/a.gsql", "SET x = 2")
    Guardian.Test.FakeS3.put_object(s3, "t2/a.gsql", "SET x = 2")
    assert {:error, "no free rule module names" <> _} = Guardian.Rules.reload()
    assert Guardian.Rules.published() == before
    assert :sys.get_state(Guardian.Rules.Server).publisher == publisher

    assert Map.new(Guardian.Rules.published(), fn {table, module} -> {table, module.hash()} end) ==
             hashes

    assert :code.is_loaded(free) == false
    refute function_exported?(free, :hash, 0)
    assert [{:ok, %{"x" => 1}}] = Guardian.Engine.ingest_events("t1", [%{}])
  end

  test "repeated edits stay within the module pool, reclaiming retired modules" do
    {_s3, _store} = s3_server(rules_reclaim_after_ms: 50)
    table = unique_table("rules_pool")
    {:ok, _} = Guardian.Rules.write_rule(table, "a", "SET x = 0")
    held = Guardian.Rules.lookup(table)

    for n <- 1..40, do: {:ok, _} = Guardian.Rules.write_rule(table, "a", "SET x = #{n}")

    Guardian.Test.Polling.eventually(fn ->
      Enum.count(Guardian.Rules.Compiler.names(), &(:code.is_loaded(&1) != false)) <= 3
    end)

    refute Code.loaded?(held)
    refute function_exported?(held, :hash, 0)
    assert Guardian.Rules.lookup(table).table() == table
    assert Guardian.Rules.lookup(table).apply(%{}) == %{"x" => 40}
  end

  test "an old module stays callable until it is reclaimed" do
    {_s3, _store} = s3_server()
    table = unique_table("rules_hold")
    {:ok, _} = Guardian.Rules.write_rule(table, "a", "SET x = 0")
    held = Guardian.Rules.lookup(table)
    {:ok, _} = Guardian.Rules.write_rule(table, "a", "SET x = 1")
    {:ok, _} = Guardian.Rules.delete_rule(table, "a")
    assert held.apply(%{}) == %{"x" => 0}
    assert Guardian.Rules.lookup(table) == nil
  end

  test "a save whose outcome is unknown reports it and leaves the lock held" do
    {s3, store} = s3_server()
    table = unique_table("rules_unknown")

    # Faults apply to requests in order: the lock create, the list, then the save.
    Guardian.Test.FakeS3.fault(s3, [nil, nil, {:status, 500}])

    assert {:error, {:unknown, message}} = Guardian.Rules.write_rule(table, "a", "SET x = 1")
    assert message =~ "may have been saved"
    assert message =~ "at the latest at the next successful rule write"

    {:ok, body, _meta} = Guardian.ObjectStore.get(store, lock_key())
    assert Jason.decode!(body)["state"] == "held"
  end

  test "after a delete whose outcome is unknown, the next reload unpublishes the rule" do
    {s3, _store} = s3_server()
    table = unique_table("rules_unknown_delete")
    Guardian.Test.FakeS3.put_object(s3, "#{table}/a.gsql", "SET x = 1")
    assert :ok = Guardian.Rules.reload()
    assert is_atom(Guardian.Rules.lookup(table)) and Guardian.Rules.lookup(table) != nil

    # The lock create, the list, then the delete, which lands but answers an error.
    Guardian.Test.FakeS3.fault(s3, [nil, nil, {:applied_status, 500}])

    assert {:error, {:unknown, _message}} = Guardian.Rules.delete_rule(table, "a")
    assert Guardian.Test.FakeS3.objects(s3) |> Map.keys() |> Enum.reject(&(&1 =~ "lock")) == []
    assert :ok = Guardian.Rules.reload()
    assert Guardian.Rules.lookup(table) == nil
  end

  test "a write refuses to save with too little lease left" do
    {_s3, _store} = s3_server()
    Guardian.Test.Env.put(rules_save_margin_ms: 200_000)

    assert Guardian.Rules.write_rule(unique_table("rules_margin"), "a", "SET x = 1") ==
             {:error, "the write lock's lease ran short; retry"}
  end

  test "another writer holding the lock makes a write fail as busy, after one attempt" do
    {s3, store} = s3_server()

    {:ok, _lock} =
      Guardian.ObjectStore.Lock.acquire(store, lock_key(), "someone else")

    assert Guardian.Rules.write_rule(unique_table("rules_busy"), "a", "SET x = 1") ==
             {:error, :busy}

    # The other writer's create, then this write's one create and one read.
    assert s3
           |> Guardian.Test.FakeS3.requests()
           |> Enum.filter(&String.ends_with?(&1.path, "/" <> lock_key()))
           |> Enum.map(& &1.method) == ["PUT", "PUT", "GET"]
  end

  test "a rejected write does not hide rules another writer saved from the next reload" do
    {s3, _store} = s3_server()
    table = unique_table("rules_cache")
    Guardian.Test.FakeS3.put_object(s3, "#{table}/a.gsql", "SET x = 1")

    assert {:error, {:rejected, [_conflict]}} = Guardian.Rules.write_rule(table, "b", "SET x = 2")
    assert :ok = Guardian.Rules.reload()
    assert [{:ok, %{"x" => 1}}] = Guardian.Engine.ingest_events(table, [%{}])
  end

  test "a misnamed rule file makes its table invalid instead of dropping its rules" do
    {s3, store} = s3_server()
    table = unique_table("rules_misnamed")
    assert {:ok, _} = Guardian.Rules.write_rule(table, "a", "UNSET password")
    Guardian.Test.FakeS3.put_object(s3, "#{table}/A.gsql", "UNSET password")

    Guardian.Rules.reload()
    assert {:invalid, _message} = Guardian.Rules.lookup(table)
    assert [{:error, _}] = Guardian.Engine.ingest_events(table, [%{"password" => "p"}])

    {:ok, _} = restart_server(store)
    assert {:invalid, _message} = Guardian.Rules.lookup(table)
    assert [{:error, _}] = Guardian.Engine.ingest_events(table, [%{"password" => "p"}])
  end

  test "an oversized stored file is an error without being fetched" do
    {s3, _store} = s3_server()
    table = unique_table("rules_big")
    Guardian.Test.FakeS3.put_object(s3, "#{table}/a.gsql", String.duplicate(" ", 70_000))
    Guardian.Rules.reload()
    assert {:invalid, "#{table}/a.gsql: is over 65536 bytes"} == Guardian.Rules.lookup(table)

    refute Enum.any?(
             Guardian.Test.FakeS3.requests(s3),
             &(&1.method == "GET" and &1.path =~ table)
           )
  end
end
