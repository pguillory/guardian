defmodule Guardian.Rules.CounterReloadTest do
  use ExUnit.Case, async: false
  import Guardian.RulesTestHelper

  setup do
    s3 = Guardian.FakeS3.start()
    on_exit(fn -> Guardian.FakeS3.stop(s3) end)
    {:ok, _} = restart_server(Guardian.FakeS3.store(s3))
    %{s3: s3}
  end

  defp load(s3, files) do
    for key <- Map.keys(Guardian.FakeS3.objects(s3)),
        String.ends_with?(key, ".gsql"),
        not Map.has_key?(files, key) do
      assert :ok = Guardian.Rules.Store.delete(Guardian.FakeS3.store(s3), key)
    end

    for {key, source} <- files, do: Guardian.FakeS3.put_object(s3, key, source)
    ExUnit.CaptureLog.capture_log(fn -> assert :ok = Guardian.Rules.reload() end)
  end

  defp ingest(table, event \\ %{}) do
    assert [{:ok, row}] = Guardian.Engine.ingest_events(table, [event])
    row
  end

  defp target(module), do: Enum.find(module.plan().steps, &(&1.kind == :lookup)).target
  defp identity(module), do: Enum.find(module.plan().steps, &(&1.kind == :track)).identity

  test "valid edits switch target and dependent identities; in-flight old modules keep old state",
       %{s3: s3} do
    a = unique_table("live_target")
    b = unique_table("live_dependent")

    files = %{
      "#{a}/r.gsql" => "TRACK hits = count() LAST '1h'",
      "#{b}/r.gsql" => "LOOKUP prior = hits FROM #{a}",
    }

    load(s3, files)
    old_a = Guardian.Rules.lookup(a)
    old_b = Guardian.Rules.lookup(b)
    assert ingest(a)["hits"] == 1
    assert ingest(b)["prior"] == 1

    files = Map.put(files, "#{a}/r.gsql", "TRACK hits = sum(amount) LAST '1h'")
    load(s3, files)
    new_a = Guardian.Rules.lookup(a)
    new_b = Guardian.Rules.lookup(b)
    refute new_a == old_a
    refute new_b == old_b
    assert target(new_b).identity == identity(new_a)
    refute target(new_b).identity == target(old_b).identity
    assert ingest(b)["prior"] == nil
    assert ingest(a, %{"amount" => 7})["hits"] == 7
    assert ingest(b)["prior"] == 7
    assert old_a.apply(%{})["hits"] == 2
    assert old_b.apply(%{})["prior"] == 2
    assert ingest(b)["prior"] == 7

    # Locations affect recompilation, but not the counter's definition identity.
    moved =
      files
      |> Map.delete("#{a}/r.gsql")
      |> Map.put("#{a}/moved.gsql", "-- moved\nTRACK hits = sum(amount) LAST '1h'")

    load(s3, moved)
    assert identity(Guardian.Rules.lookup(a)) == identity(new_a)
    assert ingest(a, %{"amount" => 3})["hits"] == 10
    assert ingest(b)["prior"] == 10
  end

  test "an invalid target retains changed or deleted dependents, defers joins and allows unrelated activation",
       %{s3: s3} do
    for delete_dependent? <- [false, true] do
      a = unique_table("invalid_target")
      b = unique_table("retained_reader")
      join = unique_table("new_reader")
      other = unique_table("counter_unrelated")
      deleted = unique_table("counter_deleted")

      files = %{
        "#{a}/r.gsql" => "TRACK hits = count() LAST '1h'",
        "#{b}/r.gsql" => "LOOKUP prior = hits FROM #{a}",
        "#{other}/r.gsql" => "SET value = 1",
        "#{deleted}/r.gsql" => "SET value = 1",
      }

      load(s3, files)
      old = Map.take(Guardian.Rules.published(), [a, b])
      assert ingest(a)["hits"] == 1

      changed =
        files
        |> Map.put("#{a}/r.gsql", "TRACK hits = count() LAST '0s'")
        |> Map.put("#{other}/r.gsql", "SET value = 2")
        |> Map.delete("#{deleted}/r.gsql")
        |> Map.put("#{join}/r.gsql", "LOOKUP prior = hits FROM #{a}")

      changed =
        if delete_dependent?,
          do: Map.delete(changed, "#{b}/r.gsql"),
          else: Map.put(changed, "#{b}/r.gsql", "LOOKUP renamed = hits FROM #{a}")

      load(s3, changed)
      assert Map.take(Guardian.Rules.published(), [a, b]) == old
      assert ingest(a)["hits"] == 2
      assert ingest(b)["prior"] == 2
      assert {:invalid, _} = Guardian.Rules.lookup(join)
      assert ingest(other)["value"] == 2
      assert Guardian.Rules.lookup(deleted) == nil

      load(s3, Map.put(changed, "#{a}/r.gsql", "TRACK hits = sum(amount) LAST '1h'"))
      assert ingest(a, %{"amount" => 9})["hits"] == 9
      assert ingest(join)["prior"] == 9

      if delete_dependent?,
        do: assert(Guardian.Rules.lookup(b) == nil),
        else: assert(ingest(b)["renamed"] == 9)
    end
  end

  test "an invalid dependent retains edited, renamed, regrouped or deleted targets and new joins",
       %{s3: s3} do
    for source <- [
          "TRACK hits = sum(amount) LAST '1h'",
          "TRACK hits = count() BY ip LAST '1h'",
          "TRACK renamed = count() LAST '1h'",
          nil,
        ] do
      a = unique_table("retained_target")
      b = unique_table("invalid_reader")
      join = unique_table("deferred_reader")

      files = %{
        "#{a}/r.gsql" => "TRACK hits = count() LAST '1h'",
        "#{b}/r.gsql" => "LOOKUP prior = hits FROM #{a}",
      }

      load(s3, files)
      old = Map.take(Guardian.Rules.published(), [a, b])
      assert ingest(a)["hits"] == 1
      changed = Map.put(files, "#{b}/r.gsql", "LOOKUP prior = hits FROM #{a}; SET")

      changed =
        if source,
          do: Map.put(changed, "#{a}/r.gsql", source),
          else: Map.delete(changed, "#{a}/r.gsql")

      # A locally valid join still cannot activate into a retained component.
      counter = if source && source =~ "renamed", do: "renamed", else: "hits"
      group = if source && source =~ "BY ip", do: " BY ip", else: ""
      changed = Map.put(changed, "#{join}/r.gsql", "LOOKUP prior = #{counter} FROM #{a}#{group}")
      load(s3, changed)
      assert Map.take(Guardian.Rules.published(), [a, b]) == old
      assert ingest(a)["hits"] == 2
      assert ingest(b)["prior"] == 2
      assert {:invalid, _} = Guardian.Rules.lookup(join)
    end
  end

  test "retention follows transitive and retargeted edges from both old and new plans", %{s3: s3} do
    a = unique_table("component_a")
    b = unique_table("component_b")
    c = unique_table("component_c")
    d = unique_table("component_d")

    files = %{
      "#{a}/r.gsql" => "TRACK ca = count() LAST '1h'",
      "#{b}/r.gsql" => "TRACK cb = count() LAST '1h'; LOOKUP pa = ca FROM #{a}",
      "#{c}/r.gsql" => "LOOKUP pb = cb FROM #{b}",
      "#{d}/r.gsql" => "TRACK cd = count() LAST '1h'",
    }

    load(s3, files)
    old = Guardian.Rules.published()

    changed =
      files
      |> Map.put("#{a}/r.gsql", "SET")
      |> Map.put("#{c}/r.gsql", "LOOKUP pd = cd FROM #{d}")
      |> Map.put("#{d}/r.gsql", "TRACK cd = sum(amount) LAST '1h'")

    load(s3, changed)
    assert Guardian.Rules.published() == old
    assert ingest(a)["ca"] == 1
    assert ingest(b)["pa"] == 1
    assert ingest(c)["pb"] == 1
    assert ingest(d)["cd"] == 1

    load(s3, Map.put(changed, "#{a}/r.gsql", files["#{a}/r.gsql"]))
    assert ingest(d, %{"amount" => 8})["cd"] == 8
    assert ingest(c)["pd"] == 8
    assert ingest(b)["pa"] == 1
  end

  test "Server restart keeps published bindings and counts through invalid and unreachable stores",
       %{s3: s3} do
    a = unique_table("restart_counter")
    b = unique_table("restart_reader")

    files = %{
      "#{a}/r.gsql" => "TRACK hits = count() LAST '1h'",
      "#{b}/r.gsql" => "LOOKUP prior = hits FROM #{a}",
    }

    load(s3, files)
    old = Guardian.Rules.published()
    assert ingest(a)["hits"] == 1
    Guardian.FakeS3.put_object(s3, "#{a}/r.gsql", "TRACK hits = sum(amount) LAST '1h'")
    Guardian.FakeS3.put_object(s3, "#{b}/r.gsql", "SET")

    ExUnit.CaptureLog.capture_log(fn ->
      assert :ok = Supervisor.terminate_child(Guardian.Main, Guardian.Rules.Server)
      assert {:ok, _} = Supervisor.restart_child(Guardian.Main, Guardian.Rules.Server)
      assert :ok = Guardian.Rules.reload()
    end)

    assert Guardian.Rules.published() == old
    assert ingest(a)["hits"] == 2
    assert ingest(b)["prior"] == 2

    assert :ok = Supervisor.terminate_child(Guardian.Main, Guardian.Rules.Server)
    Guardian.FakeS3.fault(s3, {:status, 503})

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:ok, _} = Supervisor.restart_child(Guardian.Main, Guardian.Rules.Server)
      assert :sys.get_state(Guardian.Rules.Server).stale
    end)

    assert Guardian.Rules.published() == old
    assert ingest(b)["prior"] == 2
    Guardian.FakeS3.fault(s3, nil)
    Guardian.FakeS3.put_object(s3, "#{b}/r.gsql", files["#{b}/r.gsql"])
    assert :ok = Guardian.Rules.reload()
    refute Guardian.Rules.published() == old
    assert ingest(a, %{"amount" => 11})["hits"] == 11
    assert ingest(b)["prior"] == 11
  end

  test "clean boot propagates invalidity toward dependents without retaining a whole component",
       %{s3: s3} do
    a = unique_table("boot_target")
    b = unique_table("boot_invalid_reader")
    c = unique_table("boot_transitive_reader")
    Guardian.FakeS3.put_object(s3, "#{a}/r.gsql", "TRACK ca = count() LAST '1h'")

    Guardian.FakeS3.put_object(
      s3,
      "#{b}/r.gsql",
      "TRACK cb = count() LAST '1h'; LOOKUP bad = ca FROM #{a} BY ip"
    )

    Guardian.FakeS3.put_object(s3, "#{c}/r.gsql", "LOOKUP bad = cb FROM #{b}")

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:ok, _} = restart_server(Guardian.FakeS3.store(s3))
    end)

    assert ingest(a)["ca"] == 1
    assert {:invalid, _} = Guardian.Rules.lookup(b)
    assert {:invalid, _} = Guardian.Rules.lookup(c)
    assert [{:error, _}] = Guardian.Engine.ingest_events(c, [%{}])
  end

  test "dependent name and arity migrations use a new counter then retarget before deleting", %{
    s3: s3,
  } do
    a = unique_table("migration_target")
    b = unique_table("migration_reader")

    load(s3, %{
      "#{a}/r.gsql" => "TRACK hits = count() LAST '1h'",
      "#{b}/r.gsql" => "LOOKUP prior = hits FROM #{a}",
    })

    assert {:error, {:rejected, _}} =
             Guardian.Rules.write_rule(a, "r", "TRACK hits = count() BY ip LAST '1h'")

    assert {:error, {:rejected, _}} = Guardian.Rules.delete_rule(a, "r")

    assert {:ok, _} =
             Guardian.Rules.write_rule(a, "new", "TRACK grouped = count() BY ip LAST '1h'")

    assert ingest(a, %{"ip" => "a"})["grouped"] == 1
    assert {:ok, _} = Guardian.Rules.write_rule(b, "r", "LOOKUP prior = grouped FROM #{a} BY ip")
    assert {:ok, _} = Guardian.Rules.delete_rule(a, "r")
    assert ingest(b, %{"ip" => "a"})["prior"] == 1
  end
end
