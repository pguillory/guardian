# Vendored from distributed_stream 0.1.4 (https://github.com/pguillory/distributed_stream,
# commit 65ee210e3a49bc707a4effde2845c46342bdf3ce, identical to the Hex release) by
# Preston Guillory, MIT license: see lib/query/distributed_stream/LICENSE. Guardian has
# since rewritten its failure model (see "Failure model" below) and added the worker
# heap limit. Rules for editing it: lib/query/distributed_stream/CLAUDE.md.
defmodule Guardian.Query.DistributedStream do
  @moduledoc """
  A lazy, backpressured pipeline whose stages run as worker processes spread over the
  cluster. Internal to Query: `Guardian.Query.Executor` builds each query's pipeline with it,
  and the query process is the pipeline's consumer.

  A pipeline starts with `fan_out/1,2` over an enumerable (the input), which routes
  each value to a `{node, shard}` partition; `transform/2`, `map/2` and `flat_map/2`
  add work to the latest stage, run by one worker per partition; another `fan_out/2`
  starts a new stage; `fan_in/1` (or enumerating the pipeline) runs it and streams
  the output back to the calling process. Applied to a plain enumerable instead of a
  pipeline, `transform/2`, `map/2`, `flat_map/2` and `fan_in/1` run locally.
  `partitions/1` lists the cluster's partitions for a fan-out function to pick from.

  Values travel between stages in chunks of about 1,000 serialized bytes, with one
  chunk in flight per edge, so a slow stage holds back the ones before it.

  ## Failure model

  1. The consumer links a router per stage and a final router (which names the
     consumer as the last stage's receiver). Routers trap exits and start their
     workers with `Node.spawn_link/2`, so every worker's exit reason reaches its
     router; the first router likewise starts the initial worker (the process that
     reads the input).
  2. A worker or router that exits abnormally makes the whole pipeline exit with that
     reason: its router exits with it, and the link carries it to the consumer, which
     exits with it too (after stopping the rest of the pipeline, so a consumer that
     catches the exit leaves nothing running). A trapping consumer gets it as an EXIT
     message; any abnormal EXIT it receives while waiting fails it the same way.
  3. Each sender ends every edge it opened with an end-of-input marker that carries
     its chunk count, and each receiver waits for a marker from exactly the senders
     its router recorded for it. A missing chunk, a sender that died before its
     marker, or a receiver that died while its sender still needed it fails the
     pipeline.
  4. Nothing waits with a timeout. A slow stage is waited for; an abandoned pipeline
     ends through its links.
  5. Stopping enumeration early (`Enum.take/2`, a LIMIT) stops the pipeline with exit
     signals (`{:shutdown, :halted}`), which interrupt even a worker blocked in a call.

  Stages must read all of their input: a worker whose transform stops reading early
  fails the pipeline, either when a sender still needs it or, at the latest, with
  `:worker_finished_early` when it finishes.

  ## Exit reasons

  A failed pipeline exits its consumer with a `t:failure_reason/0`. `Guardian.Query.Failure`
  translates each into a `Guardian.Query.Error`; a new reason must be added to the type, this
  list and `Guardian.Query.Failure.from_exit/1` together.

  1. Any abnormal reason of a worker, router or initial worker, or of any other
     process linked to a trapping consumer, passed on unchanged: a crash reason, or
     `:noconnection` for a lost node.
  2. `{:distributed_stream, :worker_exited}`: a worker exited normally without
     reporting that it finished.
  3. `{:distributed_stream, :worker_finished_early}`: a worker finished before its
     input ended, or before its upstream stage was done.
  4. `{:distributed_stream, :input_exited}`: the initial worker exited normally
     without finishing.
  5. `{:distributed_stream, :unexpected_sender}`: a receiver got input from a sender
     its router did not record for it.
  6. `{:distributed_stream, {:lost_input, n}}`: an edge's end-of-input marker
     declared `n` more chunks than arrived (`n` is negative for a marker declaring
     fewer).
  7. `{:distributed_stream, {edge, reason}}`: the other end of an edge went down while
     still needed, with no crash reason to pass on. `edge` is `:sender_down`,
     `:receiver_down` or `:router_down`; `reason` is `:normal`, `:noproc` or
     `:noconnection`.

  The pipeline also stops its own processes with exit signals, which are never the
  consumer's exit reason: `{:shutdown, :halted}` when enumeration stopped early,
  `{:shutdown, :pipeline_failed}` when the consumer failed, and
  `{:shutdown, :consumer_exited}` from a router whose consumer exited normally.
  """

  defstruct [:input_stream, :stages]

  @typedoc """
  The reason a failed pipeline exits its consumer with; see the moduledoc. It ends in
  `term()` because other processes' reasons pass through, so it documents the tagged
  reasons rather than restricting them.
  """
  @type failure_reason ::
          {:distributed_stream,
           :worker_exited
           | :worker_finished_early
           | :input_exited
           | :unexpected_sender
           | {:lost_input, integer()}
           | {:sender_down | :receiver_down | :router_down, :normal | :noproc | :noconnection}}
          | term()

  @typedoc "Where a fan-out function sends a value: a node and a shard number on it."
  @type partition :: {node(), non_neg_integer()}

  # Only for the partition lookup in partitions/1. Stage waits have no timeout.
  @partitions_timeout 5000
  @chunk_size_bytes 1000

  @doc """
  Starts a pipeline over `stream` that sends each value to a random partition of
  `partitions/0`. Applied to a pipeline, returns it unchanged.
  """
  def fan_out(%__MODULE__{} = distributed_stream) do
    # TODO: redistribute?
    distributed_stream
  end

  def fan_out(stream) do
    fan_out(stream, random_fan_out_func())
  end

  @doc """
  Starts a new stage, run by one worker per partition that `fan_out_func` (a value to a
  `t:partition/0`) returns. Applied to a plain enumerable, starts a pipeline over it.
  """
  def fan_out(%__MODULE__{} = distributed_stream, fan_out_func)
      when is_function(fan_out_func, 1) do
    update_in(distributed_stream.stages, fn stages ->
      [{fan_out_func, []} | stages]
    end)
  end

  def fan_out(stream, fan_out_func) when is_function(fan_out_func, 1) do
    %__MODULE__{
      input_stream: stream,
      stages: [{fan_out_func, []}],
    }
  end

  # The partitions are looked up once, when the pipeline is built.
  defp random_fan_out_func do
    partitions = partitions() |> List.to_tuple()
    num_partitions = tuple_size(partitions)

    fn _ ->
      elem(partitions, :rand.uniform(num_partitions) - 1)
    end
  end

  @doc """
  The cluster's partitions: `{node, 1..n}` for each node that answers within 5 s, where
  `n` is its number of online schedulers, capped by the `:concurrency` option (default
  `:infinity`). A node whose lookup fails or times out gets no partitions, so a
  fan-out function picking from them routes its values to the other nodes.
  """
  @spec partitions(keyword()) :: [partition()]
  def partitions(opts \\ []) when is_list(opts) do
    max_concurrency = Keyword.get(opts, :concurrency, :infinity)
    {responses, _} = :rpc.multicall(__MODULE__, :node_schedulers, [], @partitions_timeout)

    # A node whose lookup fails (it lacks this module, or the call raised) gets no
    # partitions; its rows are routed to the others.
    Enum.flat_map(responses, fn
      {:badrpc, _reason} ->
        []

      {node, schedulers} ->
        concurrency = apply_max_concurrency(schedulers, max_concurrency)
        Enum.map(1..concurrency, &{node, &1})
    end)
  end

  defp apply_max_concurrency(concurrency, :infinity) do
    concurrency
  end

  defp apply_max_concurrency(concurrency, max_concurrency) do
    min(concurrency, max_concurrency)
  end

  # The target of partitions/1's multicall.
  @doc false
  def node_schedulers do
    {node(), System.schedulers_online()}
  end

  @doc """
  Adds `transform_func` (a stream to a stream) to the latest stage: each of its
  workers runs it over its input. Applied to a plain enumerable, calls it directly.
  """
  def transform(%__MODULE__{} = distributed_stream, transform_func)
      when is_function(transform_func, 1) do
    update_in(distributed_stream.stages, fn
      [{fan_out_func, transform_funcs} | stages] ->
        [{fan_out_func, [transform_func | transform_funcs]} | stages]
    end)
  end

  def transform(stream, transform_func) do
    transform_func.(stream)
  end

  @doc "`Stream.map/2` in the latest stage (or locally, for a plain enumerable)."
  def map(%__MODULE__{} = distributed_stream, map_func) do
    transform(distributed_stream, fn stream ->
      Stream.map(stream, map_func)
    end)
  end

  def map(stream, map_func) do
    Stream.map(stream, map_func)
  end

  @doc "`Stream.flat_map/2` in the latest stage (or locally, for a plain enumerable)."
  def flat_map(%__MODULE__{} = distributed_stream, map_func) do
    transform(distributed_stream, fn stream ->
      Stream.flat_map(stream, map_func)
    end)
  end

  def flat_map(stream, map_func) do
    Stream.flat_map(stream, map_func)
  end

  @doc """
  Runs the pipeline and returns its output as a stream. The process that enumerates
  the stream is the pipeline's consumer; it fails as the moduledoc describes. Applied
  to a plain enumerable, returns it unchanged.
  """
  def fan_in(%__MODULE__{input_stream: input_stream, stages: stages}) do
    Stream.resource(
      fn -> start_pipeline(input_stream, stages) end,
      &consumer_next/1,
      &consumer_after/1
    )
  end

  def fan_in(stream) do
    stream
  end

  # Every protocol message carries the pipeline's `id`, so a process taking part in
  # several pipelines (a nested pipeline's consumer is the outer one's initial worker,
  # and a consumer may run one pipeline after another) never takes one pipeline's
  # message for another's.
  defp start_pipeline(input_stream, stages) do
    id = make_ref()
    consumer = self()
    final_router = spawn_final_router(id, consumer)
    final_node = node()
    final_fan_out_func = fn _ -> {final_node, 0} end

    # Stages are stored last first, so each router is built knowing its successor.
    # The first stage's router also starts the initial worker, which reads the input.
    {later_stages, [{first_fan_out_func, first_transform_funcs}]} = Enum.split(stages, -1)

    {routers, next} =
      Enum.map_reduce(later_stages, {final_fan_out_func, final_router}, fn
        {fan_out_func, transform_funcs}, next ->
          router = spawn_router(id, next, Enum.reverse(transform_funcs), consumer, nil)
          {router, {fan_out_func, router}}
      end)

    input = {input_stream, first_fan_out_func}
    first_transform_funcs = Enum.reverse(first_transform_funcs)
    first_router = spawn_router(id, next, first_transform_funcs, consumer, input)
    linked = Map.new([first_router, final_router | routers], &{&1, true})
    %{receiver: new_receiver(id), linked: linked}
  end

  # Started by the first router, which traps exits, so however early the initial
  # worker exits, its reason reaches that router.
  defp spawn_initial_worker(id, input_stream, fan_out_func) do
    router = self()

    spawn_link(fn ->
      Guardian.Query.Limits.limit_heap()
      distribute(id, input_stream, fan_out_func, router)
      send(router, {:done, id})
    end)
  end

  # Routers

  # `input` is `{input_stream, fan_out_func}` for the first stage's router, else nil.
  defp spawn_router(id, next, transform_funcs, consumer, input) do
    spawn_link(fn ->
      Process.flag(:trap_exit, true)

      initial_worker =
        case input do
          {input_stream, fan_out_func} -> spawn_initial_worker(id, input_stream, fan_out_func)
          nil -> nil
        end

      route(%{
        id: id,
        next: next,
        transform_funcs: transform_funcs,
        consumer: consumer,
        # The first router's upstream is the initial worker, which it linked: one that
        # exits normally before its {:done} (a stream that called exit(:normal), or an
        # exit signal to itself) fails the pipeline instead of leaving this router
        # waiting. Its {:done} always arrives before its exit.
        initial_worker: initial_worker,
        # {node, shard} => worker
        workers: %{},
        # worker => MapSet of the senders that asked for it
        senders: %{},
        # Workers that reported finishing; one that exits normally without reporting
        # (an exit signal to itself) fails the pipeline.
        finished: MapSet.new(),
        exited: MapSet.new(),
        upstream_done: false,
      })
    end)
  end

  defp route(router) do
    %{id: id, consumer: consumer, senders: senders} = router
    %{initial_worker: initial_worker, upstream_done: upstream_done} = router

    receive do
      {:spawn, ^id, sender, node, shard} ->
        {worker, router} =
          case Map.fetch(router.workers, {node, shard}) do
            {:ok, worker} ->
              {worker, router}

            :error ->
              worker = spawn_worker(id, node, router.transform_funcs, router.next)
              workers = Map.put(router.workers, {node, shard}, worker)
              senders = Map.put(router.senders, worker, MapSet.new())
              {worker, %{router | workers: workers, senders: senders}}
          end

        router = update_in(router.senders[worker], &MapSet.put(&1, sender))
        send(sender, {:spawned, id, node, shard, worker})
        route(router)

      {:done, ^id} ->
        # The upstream stage has finished. Every sender blocked on our reply before
        # sending input, so each worker's sender set is complete.
        Enum.each(router.senders, fn {worker, worker_senders} ->
          send(worker, {:done, id, MapSet.to_list(worker_senders)})
        end)

        maybe_finish_route(%{router | upstream_done: true})

      # After its {:done}, the initial worker's normal exit is the expected end (the
      # {:EXIT, _pid, :normal} clause below); an abnormal one fails like any other.
      {:EXIT, ^initial_worker, :normal} when not upstream_done ->
        exit({:distributed_stream, :input_exited})

      {:finished, ^id, worker} ->
        route(%{router | finished: MapSet.put(router.finished, worker)})

      {:EXIT, ^consumer, reason} ->
        exit(consumer_exited(reason))

      {:EXIT, worker, :normal} when is_map_key(senders, worker) ->
        cond do
          not MapSet.member?(router.finished, worker) ->
            exit({:distributed_stream, :worker_exited})

          not upstream_done ->
            exit({:distributed_stream, :worker_finished_early})

          true ->
            maybe_finish_route(%{router | exited: MapSet.put(router.exited, worker)})
        end

      {:EXIT, worker, reason} when is_map_key(senders, worker) ->
        exit(reason)

      {:EXIT, _pid, :normal} ->
        route(router)

      {:EXIT, _pid, reason} ->
        exit(reason)
    end
  end

  # A router whose consumer exited normally still has to stop.
  defp consumer_exited(:normal), do: {:shutdown, :consumer_exited}
  defp consumer_exited(reason), do: reason

  # A router exits normally only after every one of its workers did.
  defp maybe_finish_route(router) do
    if router.upstream_done and map_size(router.senders) == MapSet.size(router.exited) do
      {_fan_out_func, next_router} = router.next
      send(next_router, {:done, router.id})
    else
      route(router)
    end
  end

  defp spawn_worker(id, node, transform_funcs, {fan_out_func, next_router}) do
    router = self()

    Node.spawn_link(node, fn ->
      # Read on the worker's own node, so each machine applies its own limit.
      Guardian.Query.Limits.limit_heap()

      stream =
        Stream.resource(
          fn -> new_receiver(id) end,
          &worker_next/1,
          &record_drained/1
        )

      stream = Enum.reduce(transform_funcs, stream, & &1.(&2))
      distribute(id, stream, fan_out_func, next_router)

      # A transform that stopped reading early (or never read) would otherwise finish
      # normally with partial output once its senders had all sent their markers.
      # record_drained/1 is the only writer of this key.
      unless Process.delete({__MODULE__, :drained, id}) do
        exit({:distributed_stream, :worker_finished_early})
      end

      # Sent after every marker. The router requires it before a normal exit.
      send(router, {:finished, id, self()})
    end)
  end

  # The last stage's router. Its one receiver is the consumer, which never exits
  # during the pipeline, so it starts no worker: it names the consumer to each sender
  # that asks and, once the last stage is done, tells the consumer which senders to
  # wait for, like any router tells its workers. Every sender asked before that stage
  # finished, so the set is complete, and no {:spawn} can come after.
  defp spawn_final_router(id, consumer) do
    spawn_link(fn ->
      Process.flag(:trap_exit, true)
      final_route(id, consumer, MapSet.new())
    end)
  end

  defp final_route(id, consumer, senders) do
    receive do
      {:spawn, ^id, sender, node, shard} ->
        send(sender, {:spawned, id, node, shard, consumer})
        final_route(id, consumer, MapSet.put(senders, sender))

      {:done, ^id} ->
        send(consumer, {:done, id, MapSet.to_list(senders)})

      {:EXIT, ^consumer, reason} ->
        exit(consumer_exited(reason))

      {:EXIT, _pid, :normal} ->
        final_route(id, consumer, senders)

      {:EXIT, _pid, reason} ->
        exit(reason)
    end
  end

  # Senders

  defp distribute(id, stream, fan_out_func, router) do
    edges =
      stream
      |> chunk_every_by(@chunk_size_bytes, fan_out_func)
      |> Enum.reduce(%{}, fn {{node, shard} = key, values}, edges ->
        case Map.fetch(edges, key) do
          {:ok, edge} ->
            edge = await_ready(id, edge)
            send(edge.receiver, {:input, id, self(), values})
            Map.put(edges, key, %{edge | chunks: edge.chunks + 1})

          :error ->
            # The first chunk on an edge is acknowledged before anything else, so the
            # receiver monitors this sender while it is alive: if it then dies, the
            # receiver learns the real reason, not :noproc.
            edge = open_edge(id, router, node, shard)
            send(edge.receiver, {:input, id, self(), values})
            edge = await_ready(id, edge)
            Map.put(edges, key, %{edge | chunks: 1, awaiting_ack: false})
        end
      end)

    Enum.each(edges, fn {_key, edge} ->
      send(edge.receiver, {:end_of_input, id, self(), edge.chunks})
      Process.demonitor(edge.ref, [:flush])
    end)
  end

  # The router records this sender as one of the receiver's senders before replying,
  # so no input reaches a receiver from a sender it doesn't know about.
  defp open_edge(id, router, node, shard) do
    # Monitored, so a sender whose router is gone (its pipeline was abandoned) stops
    # instead of waiting for the reply.
    router_ref = Process.monitor(router)
    send(router, {:spawn, id, self(), node, shard})

    receive do
      {:spawned, ^id, ^node, ^shard, receiver} ->
        Process.demonitor(router_ref, [:flush])
        %{receiver: receiver, ref: Process.monitor(receiver), chunks: 0, awaiting_ack: true}

      {:DOWN, ^router_ref, :process, _pid, reason} ->
        exit(edge_down_reason(:router_down, reason))
    end
  end

  # One chunk in flight per edge. A receiver that goes down (or whose node
  # disconnects) while we wait fails this sender.
  defp await_ready(_id, %{awaiting_ack: false} = edge) do
    %{edge | awaiting_ack: true}
  end

  defp await_ready(id, %{receiver: receiver, ref: ref} = edge) do
    receive do
      {:ready_for_input, ^id, ^receiver} ->
        edge

      {:DOWN, ^ref, :process, _pid, reason} ->
        exit(edge_down_reason(:receiver_down, reason))
    end
  end

  # The reason to fail with when the other end of an edge went down too early. A
  # crash reason is passed on as is: it is the same root cause the links carry, so the
  # pipeline fails with it whichever path reaches the consumer first. :noconnection
  # (which links between other nodes may never see), and :normal or :noproc (no reason
  # known), name the edge.
  defp edge_down_reason(edge, reason) when reason in [:normal, :noproc, :noconnection] do
    {:distributed_stream, {edge, reason}}
  end

  defp edge_down_reason(_edge, reason) do
    reason
  end

  # Receivers: workers and the consumer. Both gather input the same way; they differ
  # only in how they fail (worker_next/1 and consumer_next/1).

  defp new_receiver(id) do
    %{
      id: id,
      # Set by {:done, id, senders}: the senders that must each send a marker.
      expected: nil,
      # sender => %{ref, received, ended}
      edges: %{},
      # monitor ref => sender, for senders whose marker hasn't arrived
      refs: %{},
      finished: false,
    }
  end

  # A worker just exits: its router sees the reason.
  defp worker_next(receiver) do
    case gather_next(receiver, %{}) do
      {:error, reason, _receiver} -> exit(reason)
      result -> result
    end
  end

  # The consumer's state is its receiver and `linked`, the routers it linked (the
  # final one too). It fails by first stopping the rest of the pipeline, so nothing
  # is left running if the exit is caught.
  defp consumer_next(%{receiver: receiver, linked: linked} = consumer) do
    case gather_next(receiver, linked) do
      {:error, reason, receiver} ->
        # The others get a fixed reason: the real one can be large (a crash reason can
        # carry row values) and only the consumer needs it.
        stop_pipeline(%{consumer | receiver: receiver}, {:shutdown, :pipeline_failed})
        exit(reason)

      {values_or_halt, receiver} ->
        {values_or_halt, %{consumer | receiver: receiver}}
    end
  end

  # A worker's input cleanup runs whether the input ended, the transform stopped
  # reading, or gathering failed. It only records the first case: failing here would
  # replace a gather failure's reason.
  defp record_drained(%{finished: true, id: id}),
    do: Process.put({__MODULE__, :drained, id}, true)

  defp record_drained(_receiver), do: :ok

  # Returns `{values, receiver}`, `{:halt, receiver}` once every expected marker has
  # arrived, or `{:error, reason, receiver}` for the caller to fail with. `linked` is
  # the processes whose normal exit this receiver ignores (the consumer's links).
  defp gather_next(%{finished: true} = receiver, _linked) do
    {:halt, receiver}
  end

  defp gather_next(receiver, linked) do
    %{id: id, refs: refs} = receiver

    # One receive, so input, markers, {:done} and DOWNs are handled in arrival order.
    receive do
      {:input, ^id, sender, values} ->
        receiver = track(receiver, sender)
        receiver = update_in(receiver.edges[sender].received, &(&1 + 1))
        send(sender, {:ready_for_input, id, self()})
        {values, receiver}

      {:end_of_input, ^id, sender, chunks} ->
        receiver = track(receiver, sender)
        %{ref: ref, received: received} = receiver.edges[sender]

        if received != chunks do
          {:error, {:distributed_stream, {:lost_input, chunks - received}}, receiver}
        else
          Process.demonitor(ref, [:flush])
          receiver = put_in(receiver.edges[sender].ended, true)
          receiver = %{receiver | refs: Map.delete(receiver.refs, ref)}
          maybe_finish_receiver(receiver)
        end

      {:done, ^id, senders} ->
        receiver = Enum.reduce(senders, receiver, &track(&2, &1))
        maybe_finish_receiver(%{receiver | expected: MapSet.new(senders)})

      {:DOWN, ref, :process, _pid, reason} when is_map_key(refs, ref) ->
        {:error, edge_down_reason(:sender_down, reason), receiver}

      {:EXIT, pid, :normal} when is_map_key(linked, pid) ->
        {[], receiver}

      {:EXIT, _pid, reason} when reason != :normal ->
        {:error, reason, receiver}
    end
  end

  # Monitors a sender the first time we hear of it. If it is already gone, the
  # monitor reports :noproc, which fails the pipeline unless its marker came first.
  defp track(receiver, sender) do
    if Map.has_key?(receiver.edges, sender) do
      receiver
    else
      ref = Process.monitor(sender)
      edges = Map.put(receiver.edges, sender, %{ref: ref, received: 0, ended: false})
      %{receiver | edges: edges, refs: Map.put(receiver.refs, ref, sender)}
    end
  end

  defp maybe_finish_receiver(%{expected: nil} = receiver) do
    {[], receiver}
  end

  defp maybe_finish_receiver(receiver) do
    cond do
      not Enum.all?(receiver.expected, &receiver.edges[&1].ended) ->
        {[], receiver}

      map_size(receiver.edges) != MapSet.size(receiver.expected) ->
        {:error, {:distributed_stream, :unexpected_sender}, receiver}

      true ->
        {[], %{receiver | finished: true}}
    end
  end

  defp consumer_after(%{receiver: %{finished: true}, linked: linked}) do
    # Everything already finished; only drop the links and their EXIT messages.
    Enum.each(Map.keys(linked), &Process.unlink/1)
    flush_exits(linked)
  end

  defp consumer_after(consumer) do
    # Enumeration stopped early (or the consumer is failing).
    stop_pipeline(consumer, {:shutdown, :halted})
  end

  # Stops the routers with exit signals, which interrupt even a blocked process;
  # routers turn the signal into their own exit, which stops their workers (and the
  # first router's initial worker). Stopping one can make another fail first (a
  # worker whose receiver died exits abnormally), so the consumer traps exits while
  # it signals them all and only then unlinks: their exits become messages (flushed
  # below) and never kill a consumer that doesn't trap, and if the consumer itself is
  # killed meanwhile, the links still stop every process not yet signalled.
  #
  # The cost, for a consumer that doesn't trap (Guardian's query process does; a
  # nested pipeline's inner consumer, the outer initial worker, doesn't): an exit
  # signal from an unrelated link, or aimed at the consumer itself, is left as an
  # EXIT message instead of acting, but only if the consumer handles its signal queue
  # between the two flag calls. Changing the flag doesn't handle pending signals (OTP
  # 28's process_flag only sets it), so that takes being scheduled out there. A
  # 15,000-attempt targeted stress test never produced it, and
  # Guardian's inner consumer reads its input to the end or fails and exits right
  # after this.
  #
  # Messages of this pipeline already in the mailbox are dropped; any still in flight
  # carry this pipeline's id, so no later pipeline in this process takes them for its
  # own.
  defp stop_pipeline(%{receiver: receiver, linked: linked}, reason) do
    pids = Map.keys(linked)
    trapping = Process.flag(:trap_exit, true)
    Enum.each(pids, &Process.exit(&1, reason))
    Enum.each(pids, &Process.unlink/1)
    Process.flag(:trap_exit, trapping)
    flush_exits(linked)
    Enum.each(Map.keys(receiver.refs), &Process.demonitor(&1, [:flush]))
    flush_pipeline_messages(receiver.id)
  end

  defp flush_exits(linked) do
    receive do
      {:EXIT, pid, _reason} when is_map_key(linked, pid) -> flush_exits(linked)
    after
      0 -> :ok
    end
  end

  defp flush_pipeline_messages(id) do
    receive do
      {:input, ^id, _sender, _values} -> flush_pipeline_messages(id)
      {:end_of_input, ^id, _sender, _chunks} -> flush_pipeline_messages(id)
      {:done, ^id, _senders} -> flush_pipeline_messages(id)
    after
      0 -> :ok
    end
  end

  defp chunk_every_by(stream, chunk_size_bytes, fan_out_func) do
    start_func = fn ->
      %{}
    end

    reducer = fn value, acc ->
      group = fan_out_func.(value)
      {size, values} = Map.get(acc, group, {0, []})
      size = size + :erlang.external_size(value)
      values = [value | values]

      if size >= chunk_size_bytes do
        values = Enum.reverse(values)
        chunks = [{group, values}]
        acc = Map.delete(acc, group)
        {chunks, acc}
      else
        chunks = []
        acc = Map.put(acc, group, {size, values})
        {chunks, acc}
      end
    end

    last_func = fn acc ->
      chunks =
        Enum.map(acc, fn {group, {_count, values}} ->
          values = Enum.reverse(values)
          {group, values}
        end)

      {chunks, acc}
    end

    after_func = fn _acc ->
      :ok
    end

    Stream.transform(stream, start_func, reducer, last_func, after_func)
  end
end
