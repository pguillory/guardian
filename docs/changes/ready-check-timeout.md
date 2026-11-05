# ready-check-timeout: a stalled machine fails the query

Status: complete.

## Problem

Every query that reads a table, and every schema lookup (`SHOW TABLES`, `DESC`, the
`schema` table, `SELECT *` resolution), first asks each connected machine whether its
storage is ready (`Guardian.Cluster.connected_nodes/0`, 5 seconds). A machine that
answered no, still loading its segments after a boot, was left out, as intended. But
a connected machine that did not answer within 5 seconds, or whose check failed, was
left out too, with nothing logged: the query succeeded with that machine's rows
missing, an answer that read as complete. The spec stated this only for `SELECT *`
resolution.

## Behavior after the change

1. A connected machine that does not say within 5 seconds whether it is ready, or
   whose check fails, fails the query or lookup with a `Guardian.Query.Error`:
   "Temporarily unavailable: cluster node <node> (<why>); try again shortly". Over
   MCP that is a tool error, like every query error. The reason is a fixed phrase
   or the failure's kind (an exception module or exit kind), never a value.
2. A machine that answers that it is not ready (still starting, restarting its
   storage, or stopping) and a machine that is not connected are still left out,
   so rolling deploys keep answering. A machine that disconnects before it answers
   counts as disconnected.
3. A non-Guardian node connected with the cookie now fails queries instead of being
   skipped (`docs/architecture/security.md` section 6).

The cost: a machine stalled for more than 5 seconds (a long pause, overload) fails
queries for that stretch instead of answering short. A wrong count that looks right
is worse than an error the caller can retry.

## Product spec impact

1. Section 4.2's timeout paragraph: a machine that doesn't say whether it is ready
   fails the `SELECT *` lookup with the temporary error instead of being left out.
2. Section 5 item 2 no longer says "a failure never stops later events", which
   contradicted item 6: an event Guardian refuses doesn't stop later events, and an
   unexpected failure fails the whole request (`Guardian.Engine.ingest_events/2`).
3. Section 7 and section 10 item 6 state the readiness failure, and say which rows
   are still silently missing (disconnected or starting machines, and those of
   section 12).

Overview impact: none.

## Validation

`test/guardian/cluster/metadata_test.exs` (`:cluster`): a peer whose OS process is
stopped (`kill -STOP`, so it stays connected) fails `SELECT v`, `SELECT *` and
`SHOW TABLES` with the temporary error, and answers again once resumed; a peer
without Guardian's code (its check raises) fails `SELECT v`, `SELECT *` and `DESC`;
a peer that disconnects is left out; the existing test of a peer whose storage has
not started still shows it left out until ready.
