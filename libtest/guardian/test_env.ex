defmodule Guardian.TestEnv do
  @moduledoc """
  Puts `:guardian` application env for a test and restores each key's previous value
  (or removes the key if it had none) afterwards, on this node or on peers.

  Application env is node-wide, so only `async: false` tests may use it.
  """

  @doc """
  Puts `env` (a keyword list of `:guardian` keys and values) on each of `nodes`
  (by default only this one) until the calling test exits. Peers the test started do
  not load Mix config, so a peer that needs a setting must be named here.

  Returns a function that restores the values this call replaced, earlier, for a test
  whose later phases need them; the exit restore then puts back the same snapshot
  again. A peer the test has already stopped (`{:erpc, :noconnection}`) needs no
  restore and is skipped. If a later node is unreachable, the put raises, and the
  nodes already put are still restored when the test exits.
  """
  def put(env, nodes \\ [node()]) do
    restores =
      for node <- nodes do
        restore = put_on(node, env)
        # Registered per node, so a later unreachable node leaves nothing unrestored.
        ExUnit.Callbacks.on_exit(restore)
        restore
      end

    # Restore in reverse, so a node or key named twice ends at its original value.
    fn -> Enum.each(Enum.reverse(restores), & &1.()) end
  end

  @doc """
  Runs `fun` with `env` put on this node, then restores the previous values, and
  returns what `fun` returned.
  """
  def with_env(env, fun) do
    restore = put_on(node(), env)

    try do
      fun.()
    after
      restore.()
    end
  end

  defp put_on(node, env) do
    target = if node == node(), do: :local, else: {:remote, node}

    previous =
      for {key, value} <- env do
        previous = call(target, :fetch_env, [:guardian, key])
        :ok = call(target, :put_env, [:guardian, key, value])
        {key, previous}
      end

    fn -> Enum.each(Enum.reverse(previous), &restore(target, &1)) end
  end

  defp restore(target, {key, {:ok, value}}) do
    restore_call(target, :put_env, [:guardian, key, value])
  end

  defp restore(target, {key, :error}) do
    restore_call(target, :delete_env, [:guardian, key])
  end

  defp restore_call(target, function, args) do
    call(target, function, args)
  catch
    # A peer the test already stopped needs no restore.
    :error, {:erpc, :noconnection} -> :ok
  end

  defp call(:local, function, args) do
    apply(Application, function, args)
  end

  defp call({:remote, node}, function, args) do
    :erpc.call(node, Application, function, args)
  end
end
