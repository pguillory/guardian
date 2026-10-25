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
  original server is restored when the test exits.
  """
  def restart_server(store, app_env \\ []) do
    on_exit(fn ->
      Application.delete_env(:guardian, :rules_store)
      for {key, _} <- app_env, do: Application.delete_env(:guardian, key)
      stop_server()
      {:ok, _} = Supervisor.restart_child(Guardian.Main, Guardian.Rules.Server)
    end)

    stop_server()
    if store, do: Application.put_env(:guardian, :rules_store, store)
    for {key, value} <- app_env, do: Application.put_env(:guardian, key, value)
    Supervisor.restart_child(Guardian.Main, Guardian.Rules.Server)
  end

  defp stop_server do
    _ = Supervisor.terminate_child(Guardian.Main, Guardian.Rules.Server)
    :persistent_term.erase({Guardian.Rules, :tables})
  end

  @doc "Puts a module straight into the published map for `table` until the test exits."
  def publish_module(table, module) do
    Guardian.Rules.publish(Map.put(Guardian.Rules.published() || %{}, table, module))

    on_exit(fn ->
      Guardian.Rules.publish(Map.delete(Guardian.Rules.published() || %{}, table))
    end)
  end

  @doc "Puts app env for a test, restoring the previous value when it exits."
  def put_env(key, value) do
    previous = Application.fetch_env(:guardian, key)
    Application.put_env(:guardian, key, value)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:guardian, key, value)
        :error -> Application.delete_env(:guardian, key)
      end
    end)
  end

  def unique_table(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"
end
