defmodule Guardian.RulesTestHelper do
  @moduledoc """
  Helpers for rule tests, which share the test VM's one `Guardian.Rules.Server` and so must be
  `async: false`.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

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
  Restarts the test VM's Guardian.Rules.Server on `store` (or on what `env` configures) from a
  clean slate (nothing published), returning what restarting the child returned. The
  previous env and server's running/stopped state are restored when the test exits.
  """
  def restart_server(store, app_env \\ []) do
    was_running = Process.whereis(Guardian.Rules.Server) != nil
    stop_server()
    env = if store, do: [{:rules_store, store} | app_env], else: app_env
    restore = Guardian.TestEnv.put(env)

    on_exit(fn ->
      stop_server()
      restore.()
      # A previous failed start leaves invalid env but no running server. Let its
      # own cleanup restore the earlier working configuration before restarting.
      if was_running do
        {:ok, _} = Supervisor.restart_child(Guardian.Application, Guardian.Rules.Server)
      end
    end)

    Supervisor.restart_child(Guardian.Application, Guardian.Rules.Server)
  end

  defp stop_server do
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

  def unique_table(prefix) do
    "#{prefix}_#{System.unique_integer([:positive])}"
  end
end
