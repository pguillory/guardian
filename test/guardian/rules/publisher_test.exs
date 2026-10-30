defmodule Guardian.Rules.PublisherTest do
  # Not async: stops and restarts the node-wide Rules.Server.
  use ExUnit.Case, async: false
  import Guardian.Rules.Publisher
  import Guardian.Test.Rules

  alias Guardian.Rules
  alias Guardian.Rules.RuleSet

  setup do
    s3 = Guardian.Test.FakeS3.start()
    on_exit(fn -> Guardian.Test.FakeS3.stop(s3) end)
    {:ok, _} = restart_server(Guardian.Test.FakeS3.store(s3))
    :ok
  end

  # Publisher is synchronous: isolate its code loading and global publication
  # from Server. restart_server's cleanup restores the shared Server afterward.
  defp take_publisher do
    assert :ok = Supervisor.terminate_child(Guardian.Application, Rules.Server)
    new(Rules.published())
  end

  test "compiler refusal discards earlier compiled tables without changing publication or pool" do
    a = unique_table("publisher_failure_a")
    b = unique_table("publisher_failure_b")
    assert {:ok, _} = Rules.write_rule(a, "r", "SET x = 1")
    before = Rules.published()
    old = before[a]
    publisher = take_publisher()
    [first, second | _] = publisher.free

    preparation = RuleSet.prepare(%{"#{a}/r.gsql" => "SET x = 2", "#{b}/r.gsql" => "SET x = 2"})
    # Refuse the last table in the actual activation/compilation order, after the
    # first table has loaded. There is no mock compiler or production bypass.
    {refused, {:ok, plan}} = Enum.at(preparation.tables, -1)
    assert refused == b

    broken = %{
      preparation
      | tables: Map.put(preparation.tables, refused, {:ok, %{plan | resolved?: false}}),
    }

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, message, []} = activate(publisher, broken)
        assert message == "compiling the rules for #{refused} failed (unresolved_plan)"
      end)

    assert log =~ "[error] Rules: compiling the rules for #{refused} failed (unresolved_plan)"

    assert Rules.published() == before
    assert old.apply(%{}) == %{"x" => 1}

    for module <- [first, second] do
      assert :code.is_loaded(module) == false
      refute :erlang.check_old_code(module)
      refute function_exported?(module, :hash, 0)
    end

    assert {:ok, activated, []} = activate(publisher, preparation)
    assert activated.free == Enum.drop(publisher.free, 2)
    assert activated.retired[old] == :pending
    refute old in activated.free
    assert MapSet.new(Map.values(Rules.published())) == MapSet.new([first, second])
    assert Rules.lookup(a).apply(%{}) == %{"x" => 2}
    assert Rules.lookup(b).apply(%{}) == %{"x" => 2}
    assert old.apply(%{}) == %{"x" => 1}

    # Reusing the same hashes consumes no additional names or retirement slots.
    published = Rules.published()
    assert {:ok, ^activated, []} = activate(activated, preparation)
    assert Rules.published() == published
  end

  test "pool reconstruction reserves published names and retires unpublished current and old code" do
    table = unique_table("publisher_recovery")
    assert {:ok, _} = Rules.write_rule(table, "r", "SET x = 1")
    old = Rules.lookup(table)
    assert {:ok, _} = Rules.write_rule(table, "r", "SET x = 2")
    loaded = Rules.lookup(table)
    assert {:ok, _} = Rules.write_rule(table, "r", "SET x = 3")
    current = Rules.lookup(table)
    assert :ok = Supervisor.terminate_child(Guardian.Application, Rules.Server)

    # A Server can stop after deletion but before a successful soft purge.
    assert :code.delete(old)
    assert :code.is_loaded(old) == false
    assert :erlang.check_old_code(old)
    refute :code.is_loaded(loaded) == false
    publisher = new(Rules.published())
    for module <- [old, loaded, current], do: refute(module in publisher.free)
    assert publisher.retired[old] == :deleted
    assert publisher.retired[loaded] == :pending
    refute Map.has_key?(publisher.retired, current)
    assert current.apply(%{}) == %{"x" => 3}

    # Already-deleted code is only soft-purged: deleting it again would make the
    # code server report that it must be purged first.
    {reclaimed, log} = ExUnit.CaptureLog.with_log(fn -> reclaim(publisher, old) end)
    refute log =~ "must be purged"
    assert List.last(reclaimed.free) == old
    refute Map.has_key?(reclaimed.retired, old)
    refute :erlang.check_old_code(old)
    assert reclaim(reclaimed, old) == reclaimed
    assert reclaim(reclaimed, current) == reclaimed
    assert Rules.lookup(table) == current
    assert current.apply(%{}) == %{"x" => 3}
  end

  test "reclamation keeps a name retired while a process executes its old code" do
    publisher = take_publisher()
    [module | _] = publisher.free

    body =
      quote do
        def hold(parent) do
          send(parent, {:holding, self()})

          receive do
            :release -> :ok
          end
        end
      end

    {:module, ^module, _binary, _} = Module.create(module, body, Macro.Env.location(__ENV__))
    parent = self()
    {pid, ref} = spawn_monitor(fn -> module.hold(parent) end)
    on_exit(fn -> send(pid, :release) end)
    assert_receive {:holding, ^pid}

    publisher = new(Rules.published())
    deleted = reclaim(publisher, module)
    assert Process.alive?(pid)
    assert deleted.retired[module] == :deleted
    refute module in deleted.free
    assert :code.is_loaded(module) == false
    assert :erlang.check_old_code(module)

    send(pid, :release)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    reclaimed = reclaim(deleted, module)
    refute Map.has_key?(reclaimed.retired, module)
    assert List.last(reclaimed.free) == module
    refute :erlang.check_old_code(module)
    assert reclaim(reclaimed, module) == reclaimed
  end
end
