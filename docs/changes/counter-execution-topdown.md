# Top-down counter execution

Status: implemented.

Product spec impact: none. No statements change in `docs/product/overview.md` or
`docs/product/spec.md`. TRACK/LOOKUP results, fail-open defaults, bucket policy,
batching rounds, owner pipelines, deadlines and budgets are unchanged.

## Problem

Counter execution for one dependency level is spread over four places:
`Guardian.Rules.Runtime` prepares statements and catches a failed round,
`Guardian.Rules.CounterRuntime` expands buckets and combines results,
`Guardian.Counters.Machine.run_nested/3` runs rounds over an id-keyed map and
rebuilds the nesting with index offsets, and Transport answers an id-keyed map.
Nothing reads top-down as one algorithm.

## Target shape

`Guardian.Rules.CounterRuntime` becomes the one module that reads top-down:

1. `run_counters(ops, event, dispatch \\ &Client.dispatch/2)`: map each op (`{:track, definition, group, values}`
   or `{:lookup, definition, group}`) to its list of key machines; flatten;
   `run_state_machines`; unflatten against the per-op lists; combine each op with
   its finished machines into a counter result. A bucket error (timeout,
   unavailable, cooldown, budget exhausted, expired, invalid request, CAS
   conflicts exhausted) combines to `{:ok, missing}` quietly, as today.
   `{:error, failure_kind}` is reserved for exceptions: expansion raising, the
   round raising, or combination raising; the rules layer logs those.
2. `run_state_machines([]) = []`. Otherwise keep the unfinished machines, run one
   iteration over them, recurse on the stepped machines, and put the finished ones
   back among the already-finished ones. It returns finished machines in input
   order.
3. `run_one_iteration`: collect each machine's pending store op; route each op to
   its owner node (`Client.route/2`; a malformed op routes to its fixed error);
   group the routed ops by owner (`Lists.group/1`, owners sorted, ops in input
   order); dispatch the per-owner batches in parallel (`Client.dispatch/2`, one
   pipeline per owner); scatter the responses back in input order
   (`Lists.ungroup/2`, then `Lists.unfilter/3` to put routing errors back in
   place); and feed each response to its machine, which either finishes or holds
   its next op. Same order out. `run_one_iteration([])` returns `[]`, and a
   round with no routed ops (all routing errors) makes no dispatch call; this is
   how the all-finished pass of the recursion ends without dispatching.
4. Below the round loop, in the same module: bucket expansion (keys, expiry, which
   machine writes the current bucket) and combination, as today.

`Guardian.Lists` is a new leaf utility with generic single-pass list functions:
`flatten/1`, `unflatten/2` (rebuild a flat list into the shape of a nested list,
taking heads), `filter/2` and `unfilter/3` (put the filtered items back in place of
the items that matched, taking heads), `group/1` (key-value pairs into
`[{key, values}]`, keys sorted, values in input order) and `ungroup/2` (walk a key
sequence, taking the head of each key's values). No positional id maps or
index lookups. `group/1` and `ungroup/2` key a map by the semantic key (the owner
node), which is allowed; each runs in one pass plus map updates, never a list
search per item. It has three users (CounterRuntime, Rules.Runtime and Transport) and calls no
subsystem, so it is a leaf utility (listed in `lib/guardian/CLAUDE.md`).

Placement trade-off: the round loop (`run_state_machines`, `run_one_iteration`)
contains no Rules concepts and could live in Counters. It stays in
`Rules.CounterRuntime` because the target is the whole algorithm top-down in one
module and bucket expansion is Rules semantics. If a second caller of the round
loop appears, moving it to Counters is the follow-up. (Superseded: the whole
module moved to `Guardian.Counters.Execution`; see
`docs/changes/counter-execution-layer.md`.)

Layers:

- Above: `Guardian.Rules.Runtime` prepares each counter statement into one of
  three outcomes: skipped (WHERE not true; the field is not written), failed (WHERE,
  BY or argument evaluation raised; logged during preparation as today, and the
  operator's missing result is written), or runnable (an op). It runs
  `CounterRuntime.run_counters/3` on the runnable ops only (filter/unfilter), and
  writes each result into the event field; an `{:error, kind}` result is logged by
  file and line and writes the missing result. An op whose expansion failed
  reports that one failure and is not logged again if the round later raises.
  `run_counters` itself catches a raised round (routing exceptions included) and
  returns `{:error, kind}` for each op that had machines, so Runtime only logs
  results and keeps no round-level catch.
- Below: `Guardian.Counters.Machine` (a key machine: pending op or finished
  result, response callback, `advance/2` that turns a raising callback into
  `{:error, :invalid_state}`; a callback returning anything but `{:next, op,
  state}` or `{:done, result}` still raises outside that catch and fails the
  level open, as today), `Guardian.Counters.KeyMachines` (read, incr,
  gets/merge/CAS), and `Guardian.Counters.Client`/`Transport`.

`Client.batch/2` (an id-keyed map in and out) is replaced by `Client.route/2` and
`Client.dispatch/2`, delegating to Transport. `route/2` is today's
`operation_owner/2` check (operation shape, integer anchored expiry, routing key,
rendezvous owner over the event's member snapshot). `dispatch/2` takes
`[{owner, [op]}]` and returns `[{owner, [response]}]` in the same order, one
response per op. The whole round goes to one `dispatch/2` call, never one call
per owner. It accepts only ops that `route/2` accepted (documented on Client and
in `lib/guardian/counters/CLAUDE.md`); an unrouted malformed expiry would raise
inside dispatch, which cleans up its calls and fails the level open. Dispatch
runs owners in the order given; `Lists.group/1` is the one place that sorts them.
Everything that paces dispatch stays behind it in Transport: reservations, refunds, pending admission (owners without a
reservation wait for a completed pipeline's refund, or end `budget_exhausted`),
cooldown, settlement, TTL translation at actual dispatch, guard/worker dispatch,
reply-alias and monitor identity, and the remote endpoint. No budget logic moves
up. Transport's positional operation ids go: it keeps one response list per owner,
and within an owner puts operations refused at dispatch (an elapsed anchored
expiry) back among the pipeline's responses with `Lists.unfilter/3`. Budgets and
fairness are unchanged.

The round loop takes an optional dispatch function (default `Client.dispatch/2`)
so tests can script per-owner responses; routing and grouping still run in tests.
Client tests reach dispatch through a small test helper that routes, groups and
scatters with the same `Lists` functions.

## Termination

The guarantee covers the three production machines built by
`Guardian.Counters.KeyMachines` (read, incr, merge). `Machine.new/3` still accepts
any callback, and the round loop cannot itself promise that an arbitrary callback
finishes. Each production machine finishes in finitely many rounds, as today: Transport answers every
operation with a response (owner down, timeout, cooldown, exhausted budget and
invalid requests come back as errors), read and incr finish on their first
response, merge finishes after at most three gets/CAS pairs (six rounds), and a
raising callback finishes the machine with `{:error, :invalid_state}`. A round
whose transport call raises (a missing response included) fails every op of the
level open, as today. No new round cap is added.

## Behavior kept

- Buckets stay chronological with the current bucket last; numeric types and the
  `===` unchanged-state check are unchanged; one failed bucket defaults the whole
  statement while successful side effects remain; no uncertain write is retried or
  failed over; anchored TTLs are computed at dispatch; scalar preparation finishes
  before a level dispatches; LOOKUP-before-TRACK and final UNSET ordering stay.
- The same rounds, operations, owner pipelines, owner dispatch order, and order
  of statements and buckets; one dispatch call per round; none for an empty level,
  once all machines finish, or for a round of only routing errors.
- Operation order within one owner's pipeline becomes input order (statements in
  level order, buckets oldest to current). Today it is integer-id map order, which
  equals input order up to 32 operations in a round and is hash order above that.
  Store checks the deadline before each pipelined operation, so when a large
  pipeline runs out of time, which operations complete can differ. This is the
  deliberate behavior difference (approved by the tech lead): the old order above
  32 operations was an accident of map hashing. A >32-operation single-owner test
  pins input order.
- Statement failures (evaluation, expansion, a failed round, combination) default
  the statement to its operator's missing result and are logged by kind with the
  statement's file and line, through the same per-file rate limit.
- One deliberate difference in diagnostics only (accepted by the tech lead): an expansion failure (bucket
  expansion or the aggregate's start raising) is logged after the level's round
  instead of during preparation.
- Routing now runs in the round loop instead of inside Transport's batch call; a
  routing exception (members that are not a non-empty list of atoms, a
  programming error) still fails every statement of the level open, logged. When two statements in one file fail in the same
  level within a minute, which line the rate-limited log names can differ. Values
  are unchanged.

## Tests

- `Guardian.Lists` unit tests: flatten/unflatten with empty lists and empty
  inner lists; filter/unfilter with all, none and some matching; group/ungroup
  round trips with interleaved and repeated keys, sorted keys and per-key order;
  mismatched lengths or leftover/exhausted values raising.
- The three Machine tests (`machine_test.exs`) keep their assertions, ported to
  the round loop's dispatch function since `run_nested/3` goes: rounds batch every
  pending machine, empty groups and order survive, only definite conflicts retry
  (three attempts), callback exceptions are isolated, strict equality skips
  unchanged writes, and no dispatch happens for a level with no machines, after
  all machines finish, or for a round of only routing errors.
- New round-loop tests (`test/guardian/rules/counter_rounds_test.exs`): an expansion failure defaults only its own statement while
  the others run; a routing error (`invalid_request`) defaults only its statement;
  a dispatch reply of the wrong length raises and fails the level open; a
  timed-out bucket defaults its statement as `{:ok, missing}`, not an error for
  Runtime to log; more than 32 ops on
  one owner arrive in input order; interleaved owners and a routing error each get
  their own response across rounds.
- Transport: a pipeline interleaving expired anchored mutations with ready ones
  returns the right response at every position and settles only the dispatched
  operations; the all-expired full-refund path stays.
- Client tests (`client_test.exs`, and `counters/runtime_test.exs`'s one call) keep
  their assertions, written against route/dispatch through the test helper above,
  including pending-owner refunds, cooldown, deadlines, caller-death cleanup and
  malformed responses.
- Every existing CounterRuntime, Rules, Budget and counter ingest test keeps
  passing; single-statement `track`/`lookup` helpers move into the test file.

## Docs

`lib/guardian/counters/CLAUDE.md` (route/dispatch replacing the batched facade,
`operation_owner` wording, run_nested), `lib/guardian/rules/CLAUDE.md`,
`lib/guardian/CLAUDE.md` (leaf utility), `docs/architecture/system.md` (counter
execution paragraph) and TODO.md.
