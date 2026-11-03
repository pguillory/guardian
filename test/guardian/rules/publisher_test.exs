defmodule Guardian.Rules.PublisherTest do
  # Not async: stops and restarts the node-wide Rules.Server.
  use ExUnit.Case, async: false
  @moduletag :lifecycle
  import Guardian.Rules.Publisher
  import Guardian.Test.Rules

  alias Guardian.Rules
  alias Guardian.Rules.Compiler
  alias Guardian.Rules.RuleSet

  setup do
    {:ok, _} = restart_server()
    :ok
  end

  test "a compiler refusal loads nothing and changes no publication" do
    a = unique_table("publisher_failure_a")
    b = unique_table("publisher_failure_b")
    remove_on_exit(a)
    assert {:ok, _} = Rules.write_rule(a, "r", "SET x = 1")
    before = Rules.published()
    # Publisher is synchronous: isolate its code loading and global publication
    # from Server. restart_server's cleanup restores the shared Server afterward.
    assert :ok = Supervisor.terminate_child(Guardian.Application, Rules.Server)

    preparation = RuleSet.prepare(%{"#{a}/r.gsql" => "SET x = 2", "#{b}/r.gsql" => "SET x = 2"})
    # Refuse the last table in compilation order, after the first compiled. There is
    # no mock compiler or production bypass.
    {refused, {:ok, plan}} = Enum.at(preparation.tables, -1)
    assert refused == b

    broken = %{
      preparation
      | tables: Map.put(preparation.tables, refused, {:ok, %{plan | resolved?: false}}),
    }

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, message, []} = activate(broken)
        assert message == "compiling the rules for #{refused} failed (unresolved_plan)"
      end)

    assert log =~ "[error] Rules: compiling the rules for #{refused} failed (unresolved_plan)"

    assert Rules.published() == before
    assert Rules.lookup(a).apply(%{}) == %{"x" => 1}
    assert :code.is_loaded(Compiler.module_name(b)) == false

    assert {:ok, []} = activate(preparation)
    assert Rules.lookup(a) == Compiler.module_name(a)
    assert Rules.lookup(a).apply(%{}) == %{"x" => 2}
    assert Rules.lookup(b).apply(%{}) == %{"x" => 2}

    # Unchanged hashes reuse the loaded modules.
    published = Rules.published()
    assert {:ok, []} = activate(preparation)
    assert Rules.published() == published
  end
end
