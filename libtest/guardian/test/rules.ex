defmodule Guardian.Test.Rules do
  @moduledoc """
  Helpers for rule tests. `with_rules/1` is safe for async tests on their own tables:
  writes queue on the one `Guardian.Rules.Server`, so tests interleave as real callers
  do, and no two writers in this VM can meet at the store's lock. `plant_file/2` puts
  a file in the rule folder directly; an invalid one shows in every concurrent write's
  reply, so such a test is `async: false`. `stop_server/0` and `restart_server/0`
  change what that server owns and require `async: false`.
  `compile_module/2` is safe for async tests using distinct probe modules, and
  `park_in_rules_module/1` for async tests on their own tables.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]
  import ExUnit.Assertions, only: [assert: 1]

  @doc """
  Compiles and loads a resolved plan as `module`, and deletes and soft-purges it when
  the test exits.
  Safe for async tests when each test uses a distinct module.
  """
  def compile_module(module, plan) do
    on_exit(fn ->
      :code.delete(module)
      :code.soft_purge(module)
    end)

    assert {:ok, binary} = Guardian.Rules.Compiler.compile(module, plan)
    assert {:module, ^module} = :code.load_binary(module, ~c"rules/#{plan.table}", binary)
    :ok
  end

  @doc """
  Loads a module under `table`'s rules module name and parks a new process inside it,
  returning the process once it is in. The table's next rule write replaces that
  module, leaving the process in old code, which is the only way to reach the "rules
  changed too recently" outcome: rules themselves finish in milliseconds. Send the
  process `:release` to let it finish. Call it on a peer with `:erpc` to park the
  process there. The table must have no rules loaded yet. The caller releases it
  (an `on_exit` here would not work on a peer).
  """
  def park_in_rules_module(table) do
    module = Guardian.Rules.Compiler.module_name(table)

    body =
      quote do
        def park(parent) do
          send(parent, {:parked, self()})

          receive do
            :release -> :ok
          end
        end
      end

    {:module, ^module, _binary, _} = Module.create(module, body, file: "parked", line: 1)
    parent = self()
    pid = spawn(fn -> module.park(parent) end)

    receive do
      {:parked, ^pid} -> pid
    end
  end

  @doc "Writes rule files for a test and deletes them when it exits."
  def with_rules(files) do
    for {key, source} <- files do
      [table, name] = String.split(String.replace_suffix(key, ".gsql", ""), "/")
      {:ok, _} = Guardian.Rules.write_rule(table, name, source)
    end

    on_exit(fn ->
      for {key, _source} <- files do
        [table, name] = String.split(String.replace_suffix(key, ".gsql", ""), "/")
        Guardian.Rules.delete_rule(table, name)
      end
    end)

    :ok
  end

  @doc """
  Writes a file straight into the rule folder, past validation and the rule server, and
  removes its table's folder (or a file with no folder, its own) when the test exits.
  The server sees it at its next reload or write.
  """
  def plant_file(key, source) do
    path = rule_path(key)
    remove_on_exit(key)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, source)
  end

  @doc "Removes a table's rule folder when the test exits, whatever it holds by then."
  def remove_on_exit(key) do
    path = key |> Path.split() |> hd() |> rule_path()
    on_exit(fn -> File.rm_rf!(path) end)
  end

  @doc "The path of `key` in the rule folder."
  def rule_path(key) do
    {Guardian.ObjectStore.Local, %{dir: dir}} = Guardian.Rules.store()
    Path.join(dir, key)
  end

  @doc """
  Stops the test VM's Guardian.Rules.Server with nothing published, so that the next
  start is a boot. It starts again when the test exits.
  """
  def stop_server do
    on_exit(fn ->
      terminate_server()
      {:ok, _} = Supervisor.restart_child(Guardian.Application, Guardian.Rules.Server)
    end)

    terminate_server()
  end

  @doc "Stops and boots the rule server, returning what restarting the child returned."
  def restart_server do
    stop_server()
    Supervisor.restart_child(Guardian.Application, Guardian.Rules.Server)
  end

  defp terminate_server do
    _ = Supervisor.terminate_child(Guardian.Application, Guardian.Rules.Server)
    :persistent_term.erase({Guardian.Rules, :tables})
  end

  defdelegate unique_table(prefix), to: Guardian.Test.Tables
end
