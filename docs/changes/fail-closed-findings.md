# Fail-closed findings from the exception inventory

Status: complete.

Product spec impact: none. The spec already promises that a query never returns a
partial answer; these changes close holes in that promise or make a stuck state
visible. Overview impact: none. No disk format or supervision changes.

An inventory of every `rescue` and `catch` flagged a few places where a failure
turned into a quiet success. Each was checked against the code before changing it.

## Worker error collector

Query workers report the first exception they catch to a collector process and then
return no rows; the query raises the reported error once its stream ends. Two paths
read a lost report as success:

1. `Guardian.Query.WorkerErrors.first/1` returned nil when the collector was gone, so
   a recorded error read as "no error" while the worker that hit it had returned no
   rows. It now returns a `Guardian.Query.Error`, which fails the query.
2. A worker gave up waiting for its report's acknowledgement after 5 seconds and
   went on as if the report had landed. The wait now has no timeout, like every
   other pipeline wait: the collector acknowledges at once while it lives, the
   query's time limit bounds the wait, and a collector that goes down ends it.

A worker that sees the collector go down stays quiet rather than raising: either the
query is already over (a LIMIT satisfied early, or another failure), or the query's
own `first/1` call fails it. Raising there would log a crash for a query that had
already finished.

Unit tests cover the healthy relay and a collector that is gone (a process that has
already exited normally).

## Not changed: peers slow to answer the readiness check

`Guardian.Cluster.connected_nodes/0` leaves out a connected peer that does not say
within 5 seconds whether its storage is ready. Whether that should fail the query
instead is a cluster availability decision, recorded in TODO.md as
`ready-check-timeout`.
