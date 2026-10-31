defmodule Guardian.Test.Rules do
  @moduledoc """
  Helpers for rule tests. `with_rules/1` is safe for async tests on their own tables:
  writes queue on the one `Guardian.Rules.Server`, so tests interleave as real callers
  do, and no two writers in this VM can meet at the store's lock. `plant_file/2` puts
  a file in the rule folder directly; an invalid one shows in every concurrent write's
  reply, so such a test is `async: false`. `stop_server/0`, `restart_server/0` and
  `publish_module/2` change what that server owns and require `async: false`.
  `compile_module/2` is safe for async tests using distinct probe modules.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]
  import ExUnit.Assertions, only: [assert: 1]

  @doc """
  Compiles a resolved plan and deletes and soft-purges its module when the test exits.
  Safe for async tests when each test uses a distinct module.
  """
  def compile_module(module, plan) do
    on_exit(fn ->
      :code.delete(module)
      :code.soft_purge(module)
    end)

    assert Guardian.Rules.Compiler.compile(module, plan) == :ok
    :ok
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

  @doc "Puts a module straight into the published map for `table` until the test exits."
  def publish_module(table, module) do
    Guardian.Rules.publish(Map.put(Guardian.Rules.published() || %{}, table, module))

    on_exit(fn ->
      Guardian.Rules.publish(Map.delete(Guardian.Rules.published() || %{}, table))
    end)
  end

  defdelegate unique_table(prefix), to: Guardian.Test.Tables
end
