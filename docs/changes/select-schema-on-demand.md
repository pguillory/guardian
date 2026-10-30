# select-schema-on-demand: Look up schemas only for SELECT *

Status: implemented.

## Problem

Since identifiers became exact (`docs/changes/case-sensitive-identifiers.md`), the
only use of a table's schema while resolving a query is expanding `SELECT *`. The
Resolver still looked up the schema of every table any SELECT read, through
`Guardian.Cluster.Metadata`: a call to every connected machine, before the query's
30-second limit starts. So `SELECT v FROM t` paid a cluster round trip it never used,
and failed with a node error when any machine's lookup failed: after 5 seconds when a
ready machine's Storage schema or one of the table's in-memory segments did not
answer, or after up to 60 seconds when a machine stopped answering after reporting
ready.

The spec also said that a lookup waits up to 60 seconds for a machine that doesn't
answer. A machine that doesn't answer the readiness check is left out after 5
seconds, and a ready machine whose Storage schema or in-memory segment hangs fails
the lookup after 5 seconds. Only a machine that reports ready and then stops
answering takes the full 60-second call timeout.

## Behavior after the change

1. Only a SELECT whose select list has a top-level `*` (after LET substitution, which
   can introduce one, as in `LET x = *; SELECT x FROM t`) has its table's schema
   looked up while resolving. `SHOW TABLES`, `DESC` and the `schema` table still read
   schemas while the query runs, within its limit, as before.
2. A plain SELECT (columns, aggregates, `count(*)`, GROUP BY) no longer fails with a
   node error when a machine's schema lookup fails. If only the machine's schema
   bookkeeping is stuck, the query now succeeds, with that machine's rows.
3. A hung in-memory segment still fails a plain SELECT that scans it, but later: the
   scan's segment reads have no timeout of their own, so the query runs to its
   30-second time limit and fails with the time-limit query error (which does not
   name the machine) instead of a node error after about 5 seconds. Over MCP the
   client usually sees the library's 30-second timeout first, and the session is
   held for that time. Adding a timeout to scans is a separate decision, not part of
   this change.
4. A query on a table that does not exist returns what it did before (no rows, or 0
   for `count()`), without the lookup.
5. Resolving a plain SELECT on one node went from about 17-19 µs to about 6-8 µs
   (local micro-benchmark, no peers); on a cluster the saving is a round trip to
   every machine, plus each machine's in-memory segment calls, per query.

## Product spec impact

Section 4 (MCP timeout): resolution's lookup applies to `SELECT *` only, with the
5-second and 60-second cases described correctly. Section 10 item 6: the schema
lookups are named, and a segment that stops answering holds a scanning query until
its time limit. Section 12 known gap 2: the lookup delay applies to `SELECT *`.

## Validation

`test/guardian/cluster/metadata_test.exs`: with a peer whose Storage schema server is
suspended, SHOW TABLES, DESC, `SELECT key FROM schema` and `SELECT *` raise node
errors while plain SELECTs, `count()`, `count(*)` and GROUP BY succeed with the
peer's rows, and a missing table gives no rows; with a peer's in-memory segment
suspended, `SELECT *` fails with a node error and `SELECT v` with the time-limit
error. Both new tests fail before the change. `resolver_test.exs` checks that a `*`
introduced by LET is still expanded.

## Compatibility

Code only; no stored data, configuration or cross-node protocol changes. Resolution
runs only on the node that receives the query, so during a rolling deploy the
behavior depends on that node's version.
