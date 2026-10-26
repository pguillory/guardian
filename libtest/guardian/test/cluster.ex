defmodule Guardian.Test.Cluster do
  @moduledoc """
  Starts extra Guardian nodes for multi-node tests.

  Each peer is a separate BEAM node on this host, connected to the test node with
  normal distribution. A peer runs only Storage, in its own data directory, so it has
  its own tables and segments, and it appears in `Guardian.Cluster.connected_nodes/0` once its
  Storage has started.
  Web, SystemStats, and Cluster are not started on peers.

  Tests that start peers must be `async: false`: while a peer is connected, every
  query in the test VM fans out to it.
  """

  @doc """
  Starts one Storage peer and waits until it can participate in queries. Call from
  `setup` or `setup_all`; returns the peer controller and node as test context.

  On exit, stops the peer (also safe if the test stopped it), removes its data root,
  and stops distribution only if this call started it.
  """
  def single_peer do
    started_distribution = ensure_distributed()
    data_root = data_root()

    ExUnit.Callbacks.on_exit(fn ->
      File.rm_rf!(data_root)
      if started_distribution, do: Node.stop()
    end)

    {peer, peer_node} = start_peer(data_root)

    ExUnit.Callbacks.on_exit(fn ->
      try do
        :peer.stop(peer)
      catch
        :exit, _ -> :ok
      end
    end)

    await_query_node(peer_node)
    %{peer: peer, peer_node: peer_node}
  end

  @doc """
  Waits for a peer's Storage readiness and GROUP BY partition lookup. This is a
  startup barrier: a lookup that times out during a later query can still omit a
  node's partitions. It does not start Storage on peers that intentionally lack it.
  """
  def await_query_node(peer_node) do
    Guardian.Test.Polling.eventually(
      fn ->
        peer_node in Guardian.Cluster.connected_nodes() and
          Enum.any?(Guardian.Query.Executor.group_by_partitions(), fn {node, _} ->
            node == peer_node
          end)
      end,
      10_000
    )
  end

  @doc """
  Makes the test VM a distributed node if it is not one already. Returns `true` if
  this call started distribution (and so the caller should stop it).
  """
  def ensure_distributed do
    if Node.alive?() do
      false
    else
      # `erl -sname` would start epmd; Node.start/2 does not.
      {_, 0} = System.cmd(epmd_path(), ["-daemon"])
      name = :"guardian_test_#{System.unique_integer([:positive])}"
      {:ok, _} = Node.start(name, :shortnames)
      true
    end
  end

  defp epmd_path do
    case :os.find_executable(~c"epmd") do
      false ->
        erts = Path.wildcard(Path.join(:code.root_dir(), "erts-*/bin/epmd"))
        List.first(erts) || raise "epmd not found"

      path ->
        to_string(path)
    end
  end

  @doc """
  A fresh, unused data root for a peer under the system temp directory. Random rather
  than `System.unique_integer/1`, which restarts every run, so a run never reuses a
  directory an earlier run failed to remove. The caller removes it.
  """
  def data_root do
    Path.join(
      System.tmp_dir!(),
      "guardian_peer_#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
    )
  end

  @doc """
  Starts a peer node running Storage in `data_root`. Returns `{peer, node}`; stop it
  with `:peer.stop(peer)`. With `data_root` set to `nil`, the peer has Guardian's code
  but no Storage, so every Storage call on it fails. `extra_args` are passed to `erl`
  (for example `[~c"-kernel", ~c"prevent_overlapping_partitions", ~c"false"]`).
  """
  def start_peer(data_root, extra_args \\ []) do
    code_path_args = Enum.flat_map(:code.get_path(), &[~c"-pa", &1])
    cookie = Node.get_cookie() |> Atom.to_charlist()

    {:ok, peer, node} =
      :peer.start(%{
        name: :"guardian_peer_#{System.unique_integer([:positive])}",
        args: [~c"-setcookie", cookie | code_path_args] ++ extra_args,
      })

    if data_root do
      :ok = :erpc.call(node, __MODULE__, :start_storage, [data_root])
    end

    {peer, node}
  end

  @doc false
  def start_storage(data_root) do
    {:ok, _} = Application.ensure_all_started(:elixir)
    {:ok, _} = Application.ensure_all_started(:logger)
    :ok = Application.load(:guardian)
    File.mkdir_p!(data_root)
    File.cd!(data_root)
    # The peer does not load Mix config, so give Storage its data directory directly.
    Application.put_env(:guardian, :data_dir, Path.join([data_root, "data", "test"]))
    caller = self()

    # Storage links to its starter, so start it from a process that outlives this
    # RPC.
    spawn(fn ->
      {:ok, _} = Guardian.Storage.start_link([])
      send(caller, :storage_started)
      Process.sleep(:infinity)
    end)

    receive do
      :storage_started -> :ok
    after
      30_000 -> {:error, :storage_start_timeout}
    end
  end

  @doc """
  Starts Guardian.Rules.Server on this node (a peer) with `store` and extra app env, from a
  process that outlives the RPC, as `start_storage/1` does for Storage.
  """
  def start_rules(store, app_env \\ []) do
    {:ok, _} = Application.ensure_all_started(:req)
    Application.put_env(:guardian, :rules_store, store)
    for {key, value} <- app_env, do: Application.put_env(:guardian, key, value)
    caller = self()

    spawn(fn ->
      send(caller, {:rules_started, Guardian.Rules.Server.start_link([])})
      Process.sleep(:infinity)
    end)

    receive do
      {:rules_started, {:ok, _pid}} -> :ok
      {:rules_started, error} -> error
    after
      30_000 -> {:error, :rules_start_timeout}
    end
  end
end
