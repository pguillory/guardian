# Invalid stored rules fail their events, at boot and on reload alike; an unreachable store is waited for

Status: implemented and validated.

## Problem

A table whose stored rules are invalid behaves differently depending on when the
invalidity is found. At boot its events fail with `rules for <table> are invalid`,
and invalidity propagates toward LOOKUP dependents. A running machine that re-reads
the store instead keeps the table's last good rules, together with every table
connected to it through old or new LOOKUP dependencies (a "component"); deletions in
that component wait, and new tables joining it fail until it validates. This needs
prior plans recovered from the published modules (`plan/0`), a selection module
(`Guardian.Rules.Activation`), a `:reload_dependency` diagnostic, and a long spec item
that is hard to reason about. Every load also logs `Rules: N invalid: ...`.

Preston's decision: invalid stored rules have no special states. Guardian always
starts, and a table whose stored rules are invalid fails its events with
`rules for <table> are invalid` until it is fixed. Queries, the rule tools and other
tables keep working. A running machine that re-reads the store and finds an invalid
table behaves exactly as at boot; it does not keep the last good rules.

## Behavior after the change

1. Boot, reload, poll and the activation after a write all publish the same thing:
   each table's result from whole-set preparation (`RuleSet.prepare/1`). A valid
   table runs its resolved plan; an invalid one is published as
   `{:invalid, message}`; a table with no files has no rules. There is no retention,
   no deferral and no boot/reload difference.
2. A table whose LOOKUP reads a counter on an invalid table is invalid too. This is
   what `Guardian.Rules.Resolution` already does, to a fixed point: an invalid table
   defines no TRACK targets, so the dependent's LOOKUP fails to bind
   (`counter_target`). Considered alternative: let the dependent run with the
   LOOKUP failing open to its aggregate default, like a counter call failure. Not
   chosen: it needs a new "bound to a missing target" state in plans, Compiler and
   Runtime, which is more machinery, and the fixed point already exists and is the
   current boot behavior.
3. Deletions take effect on the next reload whatever else is invalid.
4. The `Rules: N invalid: ...` warning is removed. The event error names the table
   and carries its first validation message, and write and delete replies list the
   set's remaining messages. No new diagnostic surface is added.
5. Unchanged: write admission. A write or delete is refused only if it adds an error
   the stored set did not have (`RuleSet.new_errors/2`), so a write can never make a
   valid set invalid; invalid stored rules arise only from direct edits to the store,
   a newer or older build that reads the files differently, or repairing a set that
   is already broken one file at a time. A successful write's reply still lists the
   set's remaining errors.
6. A store that is unreachable or rate-limiting (HTTP 429) at boot is retried
   indefinitely, with the same backoff (1 s doubling to 10 s) and the same
   `Rules: store unreachable (...); retrying in N ms` line, instead of refusing
   startup after a minute (Preston's decision, added to this change). Guardian is not
   up while it waits. A misconfigured store (or invalid store settings) still refuses
   startup at once: retrying cannot fix it. A failed poll or reload keeps the
   published rules. A restart of the rules process alone keeps the published map in
   `:persistent_term` and re-reads the store in the background; that path reserves
   published module names from the map and never needed the prior plans.
7. Unchanged: counter identities. They derive from table, field and source digest,
   so recompiling the same TRACK after an invalid period gives the same identity and
   the same counters (whatever state survived in the Store).

## Code

- `Guardian.Rules.Activation` and its tests are deleted.
- `Guardian.Rules.Publisher.activate/2` publishes `preparation.tables` directly and
  returns `preparation.errors`; it no longer reads prior plans or logs errors.
- `Guardian.Rules.Compiler`'s generated `plan/0` (and the compile-time step-order
  reconstruction behind it) is removed: activation was its only production caller.
  Generated modules keep `table/0`, `hash/0` and `apply/1,2`. Tests that inspected
  `module.plan()` use the plan from `RuleSet.prepare/1` instead, or compare
  `hash/0`.
- `:reload_dependency` errors no longer exist.
- `Guardian.Rules.Server` drops `@boot_retry_ms` and the `:rules_boot_retry_ms`
  app env; its boot read retries until the store answers.
- Rules AGENTS.md rules 5 (validation errors are no longer logged at all), 7 and 11,
  the root AGENTS.md, `docs/architecture/system.md` (startup order, rules section,
  app-env table), `docs/architecture/security.md`, the Server, Publisher, Compiler,
  Plan and RuleSet module docs, the MCP query-language reference,
  `docs/reference/limitations.md` and the guides (`rules.md`, `cluster.md`,
  `fly.md`) follow.
- Retried at boot, as before for a minute and now indefinitely: anything the S3
  client reports as unreachable, which for reads includes a mistyped host (nxdomain)
  and TLS failures, 429 and 5xx, and rule files that keep changing during the read.
  Invalid settings, HTTP 400/401/403/404 and other non-retryable store failures
  (too many objects, an unexpected status) still refuse startup.

## Product spec impact

`docs/product/spec.md`, section 5.1.3 item 6, before:

> 6. A table whose stored rules are invalid (edited in the store by hand, or using a
>    function a newer build lacks) fails its events with `rules for <table> are invalid`
>    until fixed; other tables run normally. A running machine instead keeps that
>    table's last good rules together with all tables connected through old or new
>    LOOKUP dependencies. Deletions in that component wait too; new tables joining
>    it fail their events until the component validates. Unrelated components still
>    activate. At clean boot invalidity propagates only toward dependents. A restart
>    of the rules process retains the published plans and their identities even while
>    the rule store is unreachable. A whole node restart has no previous plans.

After:

> 6. A table whose stored rules are invalid (edited in the store by hand, or using a
>    function a newer build lacks) fails its events with `rules for <table> are invalid`
>    until fixed, at startup and after any reload alike; there are no last good rules.
>    A table whose LOOKUP reads a counter of an invalid table is invalid too. Other
>    tables, queries and the rule tools work normally. A restart of the rules process
>    keeps the published rules even while the rule store is unreachable.

Section 5.1.6, before:

> Guardian loads every rule before it loads stored events. A store it cannot
> reach, or one that rate-limits it (HTTP 429), is retried for a minute, then startup is
> refused; misconfigured store settings refuse startup at once. A rule write the store
> rate-limits fails and saves nothing.

After:

> Guardian loads every rule before it loads stored events. A store it cannot get an
> answer from (a mistyped host or a certificate failure included), or one that
> rate-limits it (HTTP 429) or fails with a server error (5xx), is retried until it
> answers, at most 10 seconds apart; Guardian is not up in the meantime. Invalid store
> settings, or a store that answers that they are wrong (HTTP 400, 401, 403 or 404),
> refuse startup at once. A rule write the store rate-limits fails and saves nothing.

Section 10 item 9, last sentence, before:

> Run one build across the cluster: older nodes that cannot load counter
> rules can retain earlier rules or reject affected tables at boot.

After:

> Run one build across the cluster: older nodes that cannot load counter
> rules fail those tables' events, or, on older builds, keep running earlier rules.

No change to `docs/product/overview.md`. The MCP query-language reference served
to clients (`lib/guardian/web/mcp/query_language.md`) changes the same way.

## Tests

- Server: a reload that finds a stored table invalid publishes it as invalid and
  fails its events (replacing "reload keeps the good module"); an unrelated write
  turns a hand-broken table invalid and reports its error (replacing "retained
  failures"); the boot-invalid test keeps its table-isolation assertions without log
  assertions; the log-format test is deleted.
- Counter reload: an invalid TRACK target makes it and its dependents invalid on
  reload while unrelated tables activate and deletions happen; repairing it
  restores the same counter identity and counts; boot and reload give the same
  publication for the same files.
- Counter plan: Activation tests are deleted; the fixed-point propagation tests stay.
- Publisher and Compiler tests drop `plan/0` assertions.

## Validation

- Code review: Codex approved; Claude asked for two stale user-facing docs
  (`limitations.md`, the local-folder paragraph of `rules.md`), fixed with its
  non-blocking items (app-env table, module docs, security.md wording on canonical
  source and on ingest errors quoting rule text, the boot-retry scope above, line
  wrapping).
- Plan review: independent Claude and Codex reviews approved; their non-blocking
  additions (security.md, the MCP reference, Plan's moduledoc, the misnamed-file and
  path-error tests, the invalid-dependent reload case) are folded in.
- `mix test test/guardian/rules` (129 tests) and, with `--include cluster`, the rules
  and cluster tests (149) pass.
- By hand, a local release (`mix release`, scheduler binding commented out for
  macOS) with an S3 endpoint at `http://localhost:1` kept logging
  `store unreachable (econnrefused); retrying` and exited 2 s after SIGTERM, so
  a stop during the wait is not blocked; `mix run --no-halt` behaved the same.
- Production holds no rule files (MCP `list_rules` returns none), so deploying
  changes nothing visible there.
