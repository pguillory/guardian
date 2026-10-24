# Query Engine

The query engine turns resolved AST statements into distributed columnar operations.

```text
AST -> Resolver -> Planner -> DistributedStream -> Evaluation -> rows
```

`Query.Resolver` expands SHOW TABLES, DESC, SELECT *, aliases, and LET substitutions,
and rewrites column names to the stored spelling ignoring case (raising
`Query.AmbiguousColumnError` when two stored names match). Evaluation looks columns up by exact
name, so statements that skip the Resolver are case-sensitive.
Schemas come from every connected node's Storage through `Cluster.Metadata`, which
adds the per-type counts together; there is no schema cache. `Query.Planner` builds
primitive steps for SELECT, WHERE, GROUP BY, HAVING, ORDER BY, and LIMIT. `Query.Evaluation`
evaluates scalar functions and operators against constants, maps, or segment columns.
Query temporaries (SELECT without FROM, the `schema` table, reassembled GROUP BY
output) are `SegmentSnapshot`s whose `columns` map holds packed binaries. Don't start
Segment processes from query code: no query process owns them long enough to stop them.

Queries are read-only. INSERT and DELETE are not statements; API ingestion uses
`/api/json/send_events`. Data leaves the store only when `Storage.SegmentExpiration`
expires old segments.

There is no user namespace; queries see every table. Preserve query-time aggregation
and scalar function behavior. Add functions under `query/function/`, register them in
`Query.Function`, and test through `Query.EvaluationTestCase`.

`Query.execute/2` is the entry point for SQL text: it resolves (the Resolver labels
each statement's columns from its pre-LET form), requires exactly one statement, and
runs it, returning a `Query.Error` from running (and a wrong statement count) as
`{:error, message}`. The JSON API, the MCP tool and the console all use it.

`Query.run/1` runs each query in its own process, the consumer of its
`Query.DistributedStream` pipeline (`lib/query/distributed_stream.ex`, vendored and
changed in Guardian; read `lib/query/distributed_stream/CLAUDE.md` before editing it).
It is internal to Query but keeps a full moduledoc: that is its failure contract. Any
worker crash or lost machine fails the whole query; it never returns partial rows, and
no pipeline stage waits with a timeout. Stages must read all their
input. `Query.run/1` stops the whole query after `Query.Limits.time_limit_ms/0`
(30 s). `Query.Limits.limit_heap/0` puts this node's `max_heap_size`
(`GUARDIAN_QUERY_MAX_HEAP_MB`, default 256, 0 off; kill, error_logger, shared binaries
not counted) on the query process and every pipeline worker, including the initial
worker but not routers; each node reads its own setting. A `:killed` exit, from a
pipeline or the query process, becomes `Query.Limits.heap_kill_message/0`, which hedges
because the reason cannot prove a heap kill. The limit does not bound total query
memory: GROUP BY state (ETS), column data (NIF native memory) and shared binaries are
not counted, GC checks can overshoot, and many processes can each reach it.
`Query.Regex.replace/3` on a value over 16 KiB runs in its own unlinked helper with
the same cap, or 256 MiB when the setting is 0, so a worker's peak can roughly double
during a replace; a helper heap kill gives null for that value, not a `:killed`
exit.
Query code reads stored segments only by ID, and only in `Query.Evaluation`:
`snapshot!/1` calls `Storage.segment_row_count/1` and `read_column/2` calls
`Storage.get_column/2` (no timeout). Both turn
`{:error, {:segment_unavailable, reason}}` into a `Query.Error` naming the segment.
AST nodes read columns through `read_column/2`, never from Storage. Query code never
holds a segment PID or calls a Storage internal module (`lib/storage/CLAUDE.md`,
"Public boundary").
`Query` keeps the API (`execute/2`, `labels/1`, `run/1`) and the query process's
lifecycle (the caller watch, the time limit). `Query.Executor` (internal) plans the
statement and runs each step in the query process; its closures are what run in
workers. `Query.Failure` turns a worker's caught exception, a pipeline exit reason, or
the query process going down into a `Query.Error` with a bounded message; reasons can
carry row values, so build such messages only through it. An exception raised in the
query process itself is re-raised to the caller unchanged.
Evaluation closures that run in workers, and GROUP BY's per-element aggregate steps,
go through `Query.WorkerErrors.guard/2`,
which reports the first exception to the query and skips the rest of that worker's
work; the query then raises it as `Query.Error`. The guard keeps row values out of
crash reports.
Raise `Query.Error` with an actionable message for failures caused by the query
itself (result and time limits); the JSON API answers it with 400. Functions and
operators never raise on a value: they give null, and strings they build are cut to
`Query.Text`'s cap (`lib/query/function/CLAUDE.md`, "Totality").
