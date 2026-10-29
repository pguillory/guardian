# Query Engine

The query engine turns resolved AST statements into distributed columnar operations.

```text
AST -> Resolver -> Planner -> DistributedStream -> Evaluation -> rows
```

`Guardian.Query.Resolver` expands SHOW TABLES, DESC, SELECT *, aliases, and LET substitutions,
and rewrites column names to the stored spelling ignoring case (raising
`Guardian.Query.AmbiguousColumnError` when two stored names match). Evaluation looks columns up by exact
name, so statements that skip the Resolver are case-sensitive.
Schemas come from every connected node's Storage through `Guardian.Cluster.Metadata`, which
adds the per-type counts together; there is no schema cache. `Guardian.Query.Planner` builds
primitive steps for SELECT, WHERE, GROUP BY, HAVING, ORDER BY, and LIMIT. `Guardian.Query.Evaluation`
evaluates scalar functions and operators against constants, maps, or segment columns.
`Guardian.Query.NativeDispatch.evaluate/3,4` owns scalar/native selection for
native-backed operations, including timestamp arithmetic and string-rendering
eligibility, on top of `Guardian.Query.ColumnOrConstant`'s column/constant
representation. Callers supply the operation and scalar callback, not a native callback
or eligibility test; a new native-backed operation gets a new `evaluate` clause there,
not its own constant-or-native helper. AND/OR retain lazy right-operand evaluation in
their AST nodes.
Query temporaries (SELECT without FROM, the `schema` table, reassembled GROUP BY
output) are `SegmentSnapshot`s whose `columns` map holds packed binaries. Don't start
Segment processes from query code: no query process owns them long enough to stop them.

Queries are read-only. INSERT and DELETE are not statements; API ingestion uses
`/api/json/send_events`. Data leaves the store only when `Guardian.Storage.SegmentExpiration`
expires old segments.

There is no user namespace; queries see every table. Preserve query-time aggregation
and scalar function behavior. Add functions under `query/function/`, register them in
`Guardian.Query.Function`, and test through `Guardian.Query.EvaluationTestCase`.

`Guardian.Query.execute/2` is the entry point for SQL text: it resolves (the Resolver labels
each statement's columns from its pre-LET form), requires exactly one statement, and
runs it, returning a `Guardian.Query.Error` from running (and a wrong statement count) as
`{:error, message}`. The JSON API and the MCP tool use it; operators can call it
directly from the remote IEx shell.

`Guardian.Query.run/1` runs each query in its own process, the consumer of its
`Guardian.Query.DistributedStream` pipeline (`lib/guardian/query/distributed_stream.ex`, vendored and
changed in Guardian; read `lib/guardian/query/distributed_stream/AGENTS.md` before editing it).
It is internal to Query but keeps a full moduledoc: that is its failure contract. Any
worker crash or lost machine fails the whole query; it never returns partial rows, and
no pipeline stage waits with a timeout. Stages must read all their
input. `Guardian.Query.run/1` stops the whole query after `Guardian.Query.Limits.time_limit_ms/0`
(30 s). `Guardian.Query.Limits.limit_heap/0` puts this node's `max_heap_size`
(256 MiB, not an operator setting; tests lower it through `:query_max_heap_mb`; kill,
error_logger, shared binaries not counted) on the query process and every pipeline
worker, including the initial worker but not routers; each node reads its own value. A `:killed` exit, from a
pipeline or the query process, becomes `Guardian.Query.Limits.heap_kill_message/0`, which hedges
because the reason cannot prove a heap kill. The limit does not bound total query
memory: GROUP BY state (ETS), column data (NIF native memory) and shared binaries are
not counted, GC checks can overshoot, and many processes can each reach it.
`Guardian.Query.Regex.replace/3` on a value over 16 KiB runs in its own unlinked helper with
the same cap, so a worker's peak can roughly double
during a replace; a helper heap kill gives null for that value, not a `:killed`
exit.
Query code reads stored segments only by ID, and only in `Guardian.Query.Evaluation`:
`snapshot!/1` calls `Guardian.Storage.segment_row_count/1` and `read_column/2` calls
`Guardian.Storage.get_column/2` (no timeout). Both turn
`{:error, {:segment_unavailable, reason}}` into a `Guardian.Query.Error` naming the segment.
AST nodes read columns through `read_column/2`, never from Guardian.Storage. Query code never
holds a segment PID or calls a Storage internal module (`lib/guardian/storage/AGENTS.md`,
"Public boundary").
`Guardian.Query` keeps the API (`execute/2`, `run/1`) and the query process's
lifecycle (the caller watch, the time limit). `Guardian.Query.Executor` (internal) plans the
statement and runs each step in the query process; its closures are what run in
workers. `Guardian.Query.Failure` turns a worker's caught exception, a pipeline exit reason, or
the query process going down into a `Guardian.Query.Error` with a bounded message; reasons can
carry row values, so build such messages only through it. An exception raised in the
query process itself is re-raised to the caller unchanged.
Evaluation closures that run in workers, and GROUP BY's per-element aggregate steps,
go through `Guardian.Query.WorkerErrors.guard/2`,
which reports the first exception to the query and skips the rest of that worker's
work; the query then raises it as `Guardian.Query.Error`. The guard keeps row values out of
crash reports.
Raise `Guardian.Query.Error` with an actionable message for failures caused by the query
itself (result and time limits); the JSON API answers it with 400. Functions and
operators never raise on a value: they give null, and strings they build are cut to
`Guardian.Query.Text`'s cap (`lib/guardian/query/function/AGENTS.md`, "Totality").

## Public boundary

Three tiers, by who may call them. There is no xref check: keep to this by convention
and in review. Tests may use any Query module.

1. The rest of Guardian (Web, Rules, Aggregation) may call `Guardian.Query`
   (`execute/2`; `run/1` runs an already-resolved statement, for tests),
   `Guardian.Query.Error`, `Limits`, `Evaluation`, `Numeric`, `Text`, and
   `Function.Interval.to_seconds/1` (Rules' interval parsing).
2. `Guardian.AST`, the parser and the nodes that evaluate themselves, is the other
   half of the engine and may also call `Eval`, `Constant`, `ColumnOrConstant`,
   `NativeDispatch`, `Regex`, `Evaluation.SegmentSnapshot`, the `Function` registry,
   and the function modules its operators share (`Function.Concat`,
   `Function.DateAdd`, `Function.DateSub`).
3. Everything else is internal to Query: `Planner`, `Executor`, `Resolver`,
   `Sorting`, `DistributedStream`, `Failure`, `WorkerErrors`, `AmbiguousColumnError`,
   `URL` and `VirtualTable.Schema`.

Modules in tiers 1 and 2 carry a moduledoc. Internal modules that carry one keep it
(for example DistributedStream's failure contract and Failure's message bounds); the
rest are `@moduledoc false`. The function modules under `function/`, including
`Function.Interval`, are documented together by the registry and `function/AGENTS.md`
rather than one moduledoc each.
