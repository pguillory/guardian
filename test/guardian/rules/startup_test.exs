defmodule Guardian.Rules.StartupTest do
  # Not async: stops and boots the node-wide Rules.Server.
  use ExUnit.Case, async: false
  @moduletag :lifecycle
  import Guardian.Test.Rules

  test "an invalid stored table is invalid at boot; other tables load" do
    bad = unique_table("boot_bad")
    good = unique_table("boot_good")
    plant_file("#{bad}/a.gsql", "SET x = nosuch(1)")
    plant_file("#{good}/a.gsql", "SET x = 1")

    {:ok, _} = restart_server()

    assert Guardian.Rules.lookup(bad) ==
             {:invalid, "#{bad}/a.gsql line 1: Invalid function nosuch"}

    assert is_atom(Guardian.Rules.lookup(good))
    assert [{:error, _}] = Guardian.Engine.ingest_events(bad, [%{}])
  end

  test "invalid counter rules at boot invalidate only their table" do
    table = unique_table("counter_boot")
    good = unique_table("counter_boot_good")
    plant_file("#{table}/a.gsql", "TRACK c = count() BY secret_group LAST '0s'")
    plant_file("#{good}/a.gsql", "SET x = 1")

    {:ok, _} = restart_server()

    assert {:invalid, _} = Guardian.Rules.lookup(table)
    assert [{:error, _}] = Guardian.Engine.ingest_events(table, [%{}])
    assert [{:ok, %{"x" => 1}}] = Guardian.Engine.ingest_events(good, [%{}])
  end

  test "invalid settings refuse startup at once" do
    stop_server()
    System.put_env("GUARDIAN_RULES_DIR", Application.fetch_env!(:guardian, :data_dir))
    on_exit(fn -> System.delete_env("GUARDIAN_RULES_DIR") end)

    assert {:error, {:rules_store, message}} =
             Supervisor.restart_child(Guardian.Application, Guardian.Rules.Server)

    assert message =~ "GUARDIAN_RULES_DIR must not be the data folder"
  end

  test "a store failing at boot is retried until it answers" do
    table = unique_table("boot_retry")
    plant_file("#{table}/a.gsql", "SET x = 1")
    stop_server()
    folder = rule_path("")
    File.chmod!(folder, 0o000)
    on_exit(fn -> File.chmod(folder, 0o755) end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        task =
          Task.async(fn ->
            Supervisor.restart_child(Guardian.Application, Guardian.Rules.Server)
          end)

        # Past the first backoff, it still hasn't come up.
        assert Task.yield(task, 1_500) == nil
        File.chmod!(folder, 0o755)
        assert {:ok, _} = Task.await(task, 30_000)
      end)

    assert log =~ "eacces; retrying in 1000 ms"
    assert is_atom(Guardian.Rules.lookup(table))
  end
end
