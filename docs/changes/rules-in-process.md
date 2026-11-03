# Rules run in the ingesting process, with no per-event limits

Status: implemented.

## Problem

`Guardian.Rules.Runner` runs a batch's rules in a spawned worker under the query heap
limit, with a 1-second limit per event. A row over either limit fails on its own and a
new worker carries on with the rest of the batch. Every row and result crosses a
process boundary, which is a real copying cost for big events, and the limits guard
against nothing Preston asked for. His decision: rules run in the process that
ingested the events, with no per-event time or memory limit. A runaway or failing rule
fails the request: let it crash.

## Behavior after the change

1. `Guardian.Rules.run_with_metadata/2` applies the table's rules to each row in turn,
   in the caller (the HTTP request process, or MCP's `send_events` worker). It looks
   up the table's module once per row, as now, so a reload between rows applies to the
   rows after it, and each event still starts its own `Guardian.Rules.Event` (arrival,
   counter membership snapshot).
2. No worker, no restart after a failure, no time or heap limit, no `rules_time_limit_ms`
   setting, and no "exceeded their time or memory limit" error. The only per-event rule
   error left is `rules for <table> are invalid (...)`.
3. A rule that raises fails the request, as before (HTTP 500, MCP -32603). The blast
   radius is unchanged: the worker's exit already became the caller's exit. Now the
   caller sees the original exception and stacktrace instead of the worker's exit.
4. Nothing bounds a row's time or memory. Rule expressions have no loops, regexes keep
   their per-start backtracking limit, built strings their 64 KiB cap, and each counter
   owner round its 50 ms. A row that used to fail at 1 s or the heap limit now finishes
   and is stored: an expensive regex (`a*[^a]` on 40 KB took 2.7 s without tripping
   its limit), many counter levels with a stalled but connected peer (each level can
   take several 50 ms rounds: gets, then add or CAS, up to three attempts), or a huge
   top-N state.
5. Module reclamation's 30 s grace period stays. Its stated reason changes: a
   generated module is on the stack only while a row reads its levels (`apply/2` tail
   calls `Runtime.run/3`), and reclamation soft-purges, so a long row can't lose its
   module mid-run. The lookup-to-call race (a process descheduled for 30 s
   between the two) was bounded by the 1 s kill and now only by scheduling: practically
   unreachable, and not guarded.

## Docs

Product spec (`docs/product/spec.md`), section 5.1.3 item 5 drops the limits; 5.1.4
item 6 drops "short of each row's rule time limit". Also: `docs/reference/api.md`,
`docs/reference/limitations.md` item 9, `docs/architecture/system.md` (ingest diagram,
3.4 Running and Activation, the settings table), `docs/architecture/security.md`
(5.2 item 7, the counter-waiting gap, 5.2.8 item 8, summary item 17),
`lib/guardian/rules/AGENTS.md` (Runner line, rules 5 and 7), `lib/guardian/engine/AGENTS.md`,
`lib/guardian/counters/AGENTS.md`, root AGENTS.md's ingest flow, and the moduledocs
and comments that say "rule worker" or cite the 1 s limit (Runtime, Execution,
Publisher, Engine, the test config and test helper). Historical change documents stay
as written.

## Tests

1. Deleted: the runner test's heap-limit test (it exists only for the limit).
2. `test/guardian/rules/runner_test.exs` becomes async, with real rules written through
   `with_rules/1` on unique tables instead of `publish_module/2`:
   - outcomes stay in order, a non-object fails alone, and caller fields named like
     arrival metadata are stored exactly as sent (nothing added); `Guardian.Rules.run/2`
     runs rules directly.
   - The invalid-table test goes: making a table invalid needs `plant_file/2`
     (`async: false`). `startup_test.exs` (a `:lifecycle` test) checks that an
     invalid table at boot fails its events with that message and stores nothing.
   - The metadata test's check that a rule module receives an arrival time between
     before and after the call goes: it needs a probe module. `event_test.exs` covers
     Event carrying the arrival, and counter window tests depend on Engine's arrival.
3. Deleted: `test/guardian/storage/segment_file_deletion_test.exs` (Preston's call: an
   undeletable segment file is a rare let-it-crash case that doesn't earn a
   synchronous test).
4. `test/guardian/rules/server_stored_files_test.exs` goes. In its place,
   `server_test.exs` (async) checks through the public API that a written rule is
   read, listed and run; deleted, it is gone, and another table keeps its rules.
   Preston's call: the planted-file cases the API can't produce (stray, misplaced,
   misnamed and oversized files, broken stored sets) and the unreadable-folder test
   go.
5. `test/guardian/rules/counter_reload_test.exs` becomes async: its valid-edit and
   migration tests write through the public API on their own tables, with no planted
   files or forced reloads. Preston's call: its invalid stored-set cases (an invalid
   target failing its dependents, an invalid dependent while its target changes) and
   its `:lifecycle` boot-versus-reload test go, since the API can't store an invalid
   file. The rule write lock test (`rules_tools_busy_test.exs`) is left as the only
   synchronous module in the default suite.

## Product spec impact

Section 5.1.3 item 5 and 5.1.4 item 6, as above. No new statements.
