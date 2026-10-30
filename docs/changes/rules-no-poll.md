# Rules change only through the service: no periodic re-read

Status: implemented.

## Problem

Every machine re-reads the rule store once a minute. Its only job that a write's
reload doesn't do is to catch changes made directly in the store, and to heal a
machine that missed a reload. Preston's decision: editing rules directly in the store
is not supported. Rules change only through the service, and whichever cluster member
takes the write tells the others to reload. The re-read and its
`Rules: reloading failed` line go.

## Behavior after the change

1. Nothing re-reads the store on a timer. The store is read at boot, in a write, when
   a writer asks a machine to reload, and once in the background after the rules
   process restarts.
2. Kept as it is: after saving, the writer publishes locally, then asks every connected
   node to reload through `:erpc.multicall` of `Guardian.Rules.reload/0` (10 s). Nodes
   that don't confirm are listed in the write's result (`unconfirmed`; MCP
   `nodes_not_yet_reloaded`). The write still succeeds: the file is saved. Only nodes
   connected at that moment can be named: a machine that is disconnected, or booting
   and not yet joined, misses the reload and appears nowhere.
3. A reload that fails when told to (store unreachable, rate-limited, no free module
   name) keeps the published rules and is not retried. It returns its error to the
   writer, which reports that node as unconfirmed; store trouble is not logged. That machine
   stays on its rules until its next reload (the next write anywhere) or restart.
4. A rules-process restart still re-reads once in the background, so a write missed
   while the process was down is picked up. If that read fails it is not retried, and
   the published rules keep serving. The next reload or write activates the store
   (`stale` stays set).
5. A file changed in the store by hand is not noticed until the next load, whatever
   triggers it, and still goes through the same validation. This is not a supported
   way of changing rules, for a bucket or for the default local folder.

### What the poll also healed

Three failures on the writing machine itself were repaired by the next poll, if
transient. All three now last until the next rule write (of any file, which activates the whole set and reloads
every node) or a restart. No timer or retry replaces them: they are rare, simplicity
wins, and the changes below tell the caller or the log.

1. Out of module names: the file is saved, local activation fails, and the reply
   lists this node in `unconfirmed`. It takes the free names running out before
   reclamation frees more (30 s), and published tables hold names too, so a set near
   the pool's 1,024 has few spare. Publisher's error drops "retrying on the next poll".
2. A compile failure at activation, which only a bug causes: same path as out of
   names. `log_poll_failure` was the only place its text appeared: the reply drops
   `local_error`'s message and a peer's reload error, so deleting that line would leave
   a bug with no trace. Publisher logs it at error level, once per failure, on any
   activation path. That is the logging policy's "a bug we need to fix", not the
   deleted store-weather line, and nothing fires on a timer now.
3. Unknown save outcome: the reply says the file may have been saved, and the machine
   does not activate or tell peers. Both unknown-outcome messages add that if it was
   saved it takes effect at the latest at the next successful rule write. ("At the latest": in
   `write/3`'s call timeout the server is still working and may finish the job itself.)
   A repeat of the same write works once the lock clears; a repeat of an unknown delete
   that did land answers "no rule file", so the message says "next rule write", not
   "retry".

### The two rule catches (16113)

Keep both; only their comments change. The reason was every node polling one store.
Without the poll it still holds:

1. `RuleSet.parse_source`'s catch-all: a write runs `prepare/1` before saving, so a
   parser bug tripped by a new file crashes only the writer's process and saves
   nothing. But a file already stored can meet a new build's bug: a deploy boots
   every node on it, and uncaught, `init/1` raises and Guardian refuses to start on
   all of them. Boot is the case that matters, and it never went away.
2. `Compiler.compile`'s rescue: compilation happens at activation, after the save, so
   a compiler bug tripped by a new file is stored first. Uncaught, it crashes the
   writer's process before the broadcast, the restart's background read crashes it
   again until the restart limit takes Guardian down, and it refuses boot. Peers
   meet the same file at their next load, and fall the same way. This one matters more
   than the parse catch, since the service's own write can reach it. Its comment's
   "tells the writer" becomes "logs it" (a compile failure at boot still refuses
   startup, as today).

CONTRIBUTING's reason 6 (Isolation: "a stored rule file tripping a bug on every node
at once") stays true as written.

## Code

- `Guardian.Rules.Server`: remove `poll_ms/0`, the `:rules_poll_ms` app env,
  `schedule_poll/0`, `log_poll_failure/2` and `poll_logged_at`. `restart/2` sends one
  `:catch_up` message, handled by one `reload_state/1` whose error is dropped.
- Publisher: error text, and `Logger.error` where `Compiler.compile` returns an error.
  Both unknown-outcome messages in Server.
- Comments on the two catches and on `ObjectStore.S3`'s "polls this on every node".
  Module docs of `Rules`, `Rules.Server`, `Rules.Config`.

## Tests

- Goes: `polling picks up changes made to the store directly` (server_test) and its
  `wait_until` helper, now unused.
- Replaced: cluster_test's `a node that missed a reload catches up by polling` becomes
  `a node that missed a reload catches up at the next write`: it asserts the peer
  lacks the planted rule first, and has it after an unrelated write. `s3_cluster`'s
  and `start_rules`'s env arguments go if nothing else passes them.
- New: the compile-failure log line, in the existing Publisher refusal test.
- Not kept: tests of a rules-process restart's one read and of the next write
  activating after running out of names. They restart the process and rewrite its
  pool, which CONTRIBUTING's testing philosophy rules out. Both passed once before
  they were removed; the restart read has no test, as before this change.
- The restart-env test uses another app env key in place of `rules_poll_ms`.
- No test asserts the `reloading failed` line. The `capture_log` wrappers around
  `Guardian.Rules.reload()` and around the plain write in server_test (and the one in
  counter_reload_test) can't see it or anything else, since the poll was its only
  source and neither logs, so they go, keeping the asserts inside them. The wrappers
  around boot and around unknown saves stay.
- Tests that plant a file with `FakeS3.put_object` then call `reload/0` stay: they
  stand in for a file another build reads differently or another writer saved.
  `hand-broken` in one test name becomes `broken`.

## Docs

`docs/architecture/system.md`, `docs/architecture/security.md` (items on when the
store is read; "those writes still go through validation at load" gains "at the
next load"; the stalled write's "every node then fails" becomes "each node then fails from its
next load"), `docs/guides/rules.md`, `docs/reference/limitations.md` (the same two
points),
`lib/guardian/AGENTS.md`, `lib/guardian/rules/AGENTS.md`, and a superseded note at the
top of `docs/changes/invalid-rules-fail-events.md`. That document's items 1, 5 and 6
name the poll and direct edits; it stays as history. None of its listed tests goes
stale.

TODO: `rules-reread-on-reconnect`, open, for when a cluster is real: a machine that
misses a reload stays on old rules until the next write or restart, whether it was
disconnected or still booting (rules load first, cluster discovery last); re-read on
join and reconnect is the likely answer. Also covers a reload or restart read that
failed.

## Product spec impact

`docs/product/spec.md`, section 5.1.3 item 6, before:

> 6. A table whose stored rules are invalid (edited in the store by hand, or using a
>    function a newer build lacks) fails its events with `rules for <table> are invalid`

After:

> 6. A table whose stored rules are invalid (using a function a newer build lacks, or
>    left by a stalled write, section 12) fails its events with `rules for <table> are invalid`

Section 5.1.5 item 2, last sentence, before:

> Machines also re-read the store every minute, catching changes made directly in the store.

After:

> Rules change only through these writes; editing the store directly is not supported.
> A machine that misses the reload keeps its rules until the next write or until it
> restarts. The write's reply names a connected machine that didn't confirm; one not
> connected at the time isn't named.

Section 5.1.5 item 4, last sentence, before:

> Rapid edits with many dependents can exhaust the bounded compiled-module pool; the
> file may be saved while activation waits for reclamation and the next poll.

After:

> Rapid edits with many dependents can exhaust the bounded compiled-module pool; the
> file may be saved without taking effect, and the reply names the machine. The next
> rule write activates it, once reclamation has freed names.

The MCP tools item (`docs/product/spec.md` around line 236), before:

> validation errors the set still has (from before this write), and any machine that
> has not yet confirmed loading it (it catches up within a minute). A write whose
> outcome is unknown says it may have been saved.

After:

> validation errors the set still has (from before this write), and any machine that
> is connected but has not confirmed loading it (it catches up at the next write or
> restart). A write whose outcome is unknown says it may have been saved, and if it
> was, it takes effect at the latest at the next successful rule write.

Section 12: a new item for a machine missing a reload (not connected, or failed),
matching 5.1.5 item 2 and `docs/reference/limitations.md`.

No change to `docs/product/overview.md`.

## Validation

- Plan review: Codex approved. Claude asked for the compile-failure log and for the
  reply's connected-only wording; both are in, and its re-review approved.
- Code review: Codex and Claude approved. Their non-blocking items are in: restart
  and pool-rewriting tests removed, "next successful rule write", line wrapping, and
  the security log inventory.
- `mix test test/guardian/rules test/guardian/web/mcp/rules_tools_test.exs
  test/guardian/object_store --include cluster`: 169 tests pass, with no log output.
