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

## A segment stuck while packing

The persister packs each full segment through 5-second calls before writing its
file. A segment that died is unregistered when its exit arrives, and a crash logs
itself. But a live segment that kept missing the call timeout was retried every
second with nothing logged, while its rows stayed only in memory. A call timeout now
goes through the same path as a failed write: logged once at error level, retried
every pass, and forgotten once the segment persists. A segment that is merely slow
logs once and then persists quietly.

There is no test: producing a stuck segment means freezing a segment process, which
the testing rules rule out. The one test that did that, suspending a segment past
the timeout to check the persister survives its late reply, is removed: it now logs
an error on purpose, which the logging rules rule out too.

## A lock of unknown age

The S3 client read an object's age from its Last-Modified header and the store's
Date, and gave 0 when Last-Modified was missing or did not parse. The lease lock takes
over a held lock only once that age passes the lease, so with such a store a crashed
writer's lock was never taken over and every rule write answered busy forever, with
nothing saying why. Real S3 and R2 send a parseable Last-Modified, so this needs an
unusual S3-compatible store.

The age is now nil when the store does not give one (`Guardian.ObjectStore`'s
`meta` type allows it), and acquiring a held lock of unknown age fails with
`{:failed, "lock age unknown"}`, which a rule write reports as "store request failed
(lock age unknown)". A released lock is still taken over whatever its age. Other
reads do not need the age, so they are unaffected.

Tests cover the age parsing and the lock's decision, through a stub store whose
object has no age.

## Not changed: peers slow to answer the readiness check

`Guardian.Cluster.connected_nodes/0` leaves out a connected peer that does not say
within 5 seconds whether its storage is ready. Whether that should fail the query
instead is a cluster availability decision, recorded in TODO.md as
`ready-check-timeout`.
