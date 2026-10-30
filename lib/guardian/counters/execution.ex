defmodule Guardian.Counters.Execution do
  @moduledoc """
  Counter execution for one dependency level, top-down: the counters layer below
  `Guardian.Rules.Runtime`, which prepares each TRACK/LOOKUP statement as an op and
  writes the results into event fields.

  `run_counters/4` expands each op into one key machine per bucket, runs every
  machine of the level together in rounds (`run_state_machines/3`), and combines
  each op's finished machines into its counter result. Each round routes the
  pending store operations to their owner nodes, groups them by owner and sends the
  round's owner batches through one `Guardian.Counters.Client.dispatch/2` call, then
  feeds each response back to its machine. This module is the one place that orders
  a round's owners: `Guardian.Lists.group/1` sorts them ascending, keeping each
  owner's operations in input order, and dispatch starts owners in the order given.
  The key machines are `Guardian.Counters.KeyMachines`.

  Its inputs are counters-layer values: ops carrying `Guardian.Counters.Definition`s,
  the event's `Guardian.Counters.Arrival` and its `Guardian.Counters.Context`.

  The production machines (read, incr, merge) finish in at most six rounds: every
  routed operation gets a response, failures included, read and incr finish on
  their first response, and merge retries only definite CAS conflicts, with three
  total attempts.
  """
  alias Guardian.Aggregation
  alias Guardian.Counters.Arrival
  alias Guardian.Counters.Client
  alias Guardian.Counters.Context
  alias Guardian.Counters.Definition
  alias Guardian.Counters.KeyMachines
  alias Guardian.Counters.Machine
  alias Guardian.Lists

  @counts [{"count", 0}, {"count", 1}]

  @type op ::
          {:track, Definition.t(), tuple(), [term()]}
          | {:lookup, Definition.t(), tuple()}

  @doc """
  One result per op, in order. A failed bucket (timeout, unavailable, cooldown,
  exhausted budget, expiry, invalid request) defaults its op to the operator's
  missing result, `{:ok, missing}`. `{:error, failure_kind}` means expansion, the
  round or combination raised; the caller logs it and writes the missing result.
  """
  @spec run_counters([op()], Arrival.t(), Context.t(), function()) :: [
          {:ok, term()} | {:error, String.t()},
        ]
  def run_counters(ops, arrival, context, dispatch \\ &Client.dispatch/2) do
    expanded = Enum.map(ops, &expand(&1, arrival))
    nested = Enum.map(expanded, &machines/1)

    try do
      nested
      |> Lists.flatten()
      |> run_state_machines(context, dispatch)
      |> Lists.unflatten(nested)
    catch
      kind, reason ->
        failure = Guardian.Failure.kind(kind, reason, __STACKTRACE__)
        Enum.map(expanded, &round_failed(&1, failure))
    else
      finished -> Enum.zip_with(expanded, finished, &combine/2)
    end
  end

  @doc """
  Runs machines until every one has finished, returning them in input order.
  `dispatch` sends a round's owner batches (`Guardian.Counters.Client.dispatch/2`).
  """
  @spec run_state_machines([%Machine{}], Context.t(), function()) :: [
          %Machine{},
        ]
  def run_state_machines(machines, context, dispatch \\ &Client.dispatch/2)

  def run_state_machines([], _context, _dispatch) do
    []
  end

  def run_state_machines(machines, context, dispatch) do
    unfinished = Lists.filter(machines, &running?/1)
    stepped = run_one_iteration(unfinished, context, dispatch)
    finished = run_state_machines(stepped, context, dispatch)
    Lists.unfilter(finished, machines, &running?/1)
  end

  # Routes each machine's pending operation to its owner, sends one batch per owner
  # in parallel, and feeds each response, in order, back to its machine. A malformed
  # operation's routing error is its response.
  defp run_one_iteration([], _context, _dispatch) do
    []
  end

  defp run_one_iteration(machines, context, dispatch) do
    routes = Enum.map(machines, &route(&1.op, context))
    routed = Lists.filter(routes, &routed?/1)

    responses =
      routed
      |> send_batches(context, dispatch)
      |> Lists.unfilter(routes, &routed?/1)

    Enum.zip_with(machines, responses, &Machine.advance/2)
  end

  defp send_batches([], _context, _dispatch) do
    []
  end

  defp send_batches(routed, context, dispatch) do
    owners = Enum.map(routed, fn {:ok, owner, _op} -> owner end)
    batches = routed |> Enum.map(fn {:ok, owner, op} -> {owner, op} end) |> Lists.group()
    batches |> dispatch.(context) |> Lists.ungroup(owners)
  end

  defp route(op, context) do
    case Client.route(op, context) do
      {:ok, owner} -> {:ok, owner, op}
      error -> error
    end
  end

  defp routed?(route) do
    match?({:ok, _owner, _op}, route)
  end

  defp running?(machine) do
    not Machine.done?(machine)
  end

  # An op's aggregation and bucket machines, or the expansion's failure kind.
  defp expand(op, arrival) do
    aggregation = Definition.aggregation(elem(op, 1))
    {:ok, aggregation, expand_machines(op, aggregation, arrival)}
  catch
    kind, reason -> {:error, Guardian.Failure.kind(kind, reason, __STACKTRACE__)}
  end

  defp machines({:ok, _aggregation, machines}) do
    machines
  end

  defp machines({:error, _kind}) do
    []
  end

  defp expand_machines({:lookup, definition, group}, _aggregation, arrival) do
    Enum.map(keys(definition, group, arrival), &KeyMachines.read/1)
  end

  defp expand_machines({:track, definition, group, values}, aggregation, arrival) do
    operator = definition.operator
    delta = Aggregation.start(aggregation, values)
    keys = keys(definition, group, arrival)

    if operator in @counts and delta == 0 do
      Enum.map(keys, &KeyMachines.read/1)
    else
      {previous, [current]} = Enum.split(keys, -1)
      expiry = expiry(definition, arrival)

      writer =
        if operator in @counts,
          do: KeyMachines.incr(current, delta, expiry),
          else: KeyMachines.merge(aggregation, current, delta, expiry)

      # Keep the current bucket last: min/max ties and floating sums depend on order.
      Enum.map(previous, &KeyMachines.read/1) ++ [writer]
    end
  end

  # A raised round fails every op that dispatched machines; expansion failures
  # keep their own kind.
  defp round_failed({:ok, _aggregation, []} = expanded, _failure) do
    combine(expanded, [])
  end

  defp round_failed({:ok, _aggregation, _machines}, failure) do
    {:error, failure}
  end

  defp round_failed({:error, _kind} = error, _failure) do
    error
  end

  # A failed expansion has no machines (machines/1), so nothing finished for it.
  defp combine({:error, _kind} = error, []) do
    error
  end

  defp combine({:ok, aggregation, _machines}, finished) do
    results = Enum.map(finished, & &1.result)

    if Enum.any?(results, &match?({:error, _}, &1)) do
      {:ok, Aggregation.default(aggregation)}
    else
      results
      |> Enum.reduce(Aggregation.empty(aggregation), fn
        :not_found, acc -> acc
        {:ok, state}, acc -> Aggregation.merge(aggregation, acc, state)
      end)
      |> then(&{:ok, Aggregation.finish(aggregation, &1)})
    end
  catch
    kind, reason -> {:error, Guardian.Failure.kind(kind, reason, __STACKTRACE__)}
  end

  defp keys(definition, group, arrival) do
    first = Integer.floor_div(arrival.unix_ms - definition.window_ms, definition.bucket_ms)
    last = Integer.floor_div(arrival.unix_ms, definition.bucket_ms)
    for bucket <- first..last, do: {definition.identity, group, bucket}
  end

  defp expiry(definition, arrival) do
    bucket = Integer.floor_div(arrival.unix_ms, definition.bucket_ms)
    unix_expiry = (bucket + 1) * definition.bucket_ms + definition.window_ms
    arrival.monotonic_ms + unix_expiry - arrival.unix_ms
  end
end
