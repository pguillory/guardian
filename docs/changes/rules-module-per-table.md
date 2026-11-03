# One compiled module per table, swapped in place

Status: implemented.

## Problem

Each change to a table's rules compiles into a free name from a pool of 1,024
generated modules (`Guardian.Rules.Compiled.M0`...). A module the published map stops
using is retired, then 30 s later deleted and soft-purged, and its name returns to the
pool only once the purge succeeds. That keeps atoms bounded and never reloads a name
while something can call it, at the cost of a pool, retirement statuses, reclamation
timers, a restart-time pool rebuild, a configuration key and the "rapid edits can
exhaust the pool" limitation.

Preston's decision: each table's rules compile to one module whose name is computed
from the table, so atoms are bounded by the number of tables. A rule write replaces
that module with the VM's normal hot code swap. Before loading a new version, the old
one is purged softly. If a process is still running the old code, the write fails
with a short "rules changed too recently" error and nothing changes. Rules run in
milliseconds, and a generated module is on a stack only while a row reads its levels
(`apply/2` tail-calls `Runtime.run/3`), so this needs two writes to the same table
microseconds to milliseconds apart. Running processes are never killed.

## Facts this relies on (checked on OTP 28.5)

1. `:code.load_binary/3` over a module that already has old code does not fail: it
   hard-purges the old code first, killing any process still in it. So every load
   must be preceded by a successful `:code.soft_purge/1` of that module, and only one
   process (Rules.Server) loads these modules, so nothing can create old code between
   the purge and the load.
2. A process that merely holds a literal from the old code (a `levels()` value) does
   not block `soft_purge`; the purge copies the literal into its heap. Only a process
   executing old code does.
3. `:code.delete/1` refuses while old code exists, for the same reason.

## Module names

`Guardian.Rules.Compiler.module_name(table)` is
`:"Elixir.Guardian.Rules.Compiled.<table>"`, the table name verbatim.

1. No collision between tables: table names match `[a-z_][a-z0-9_]*`
   (`Guardian.Engine.valid_table_name?/1`, checked on every rule path), so they contain
   no `.`; a fixed prefix plus distinct dot-free suffixes gives distinct atoms.
2. No clash with real modules: the `Elixir.Guardian.Rules.Compiled.` prefix is reserved
   for generated modules. Nothing in Guardian, its dependencies or OTP uses it, the
   namespace test checks that no application module is under it, and a lowercase last
   segment can't be written as an ordinary alias (only as a quoted atom, which nothing
   does).
3. Atom length: the prefix is 31 characters and table names are at most 64 bytes, so a
   name is at most 95 characters, under the VM's 255-character atom limit.
4. Atom count: one atom per distinct table name a valid rule write has named on the
   node since it started (the pre-save check creates it on every node, even if the
   write is then refused or fails), and one loaded module per table that has had
   rules. At most 256 tables have rules at a time (`RuleSet.max_tables/0`), but
   deleting and creating differently named tables grows both until restart, so there
   is no fixed bound. Only the admin key can write rules. `module_name/1` raises on an
   invalid table name (only a bug can pass one). This is the one place `lib/` turns a
   string into an atom; the security doc's "no atom injection" item says so.

## Behavior after the change

### Activation (boot, reload, write; Publisher)

Publisher becomes stateless functions called from Server's callbacks:

1. As now, each table's preparation result decides its target: an invalid table is
   published as `{:invalid, message}`; a valid table whose published module's
   `hash/0` equals its plan's hash keeps it; any other valid table needs a load.
2. Compile every table that needs a load to a binary, without loading anything
   (`:compile.forms/2` from a fixed Erlang abstract-format template, which replaces
   the `Module.create/3` quote: `table/0`, `hash/0`, `apply/1`, `apply/2` and the
   levels as one literal from `:erl_parse.abstract/1`). `Module.create/3` cannot be
   kept: it loads as it compiles, and warns on every redefinition. A compile failure
   (only a bug) fails the activation with nothing loaded, as now.
3. Soft-purge each of those modules. If any purge fails, the activation fails with
   "rules changed too recently; try again" and nothing is loaded. (A successful purge
   of old code that nothing runs changes nothing observable.)
4. Load every binary at once with `:code.atomic_load/1` (which refuses, rather than
   kills, a module with old code), then publish the map. Changed tables switch
   together at the load; new and invalid tables at the publish, an instant later.
5. A table whose rules are all deleted, or that becomes invalid, leaves the published
   map; its module stays loaded but nothing calls it (Runner calls only what the map
   names). Keeping it avoids a race where an event that read the map just before the
   publish calls a deleted module and fails. Writing rules for the table again swaps
   that module like any change. The cost is one idle module per such table until the
   node restarts.

There is no pool, retirement, reclamation timer, `{:reclaim, module}` message,
restart-time pool rebuild or `rules_reclaim_after_ms` key. A Server restart keeps the
published map and loaded modules and needs no Publisher state.

### Writes: nothing changes on any node

The too-recent check must run before the save, on every connected node, since a peer
that loads the change after the save could otherwise be the one that fails. Under the
write lock, after admission (validation) succeeds:

1. The writer takes the new set's valid tables and plan hashes (`Publisher.hashes/1`,
   small).
2. Each node, the writer in its own callback and every connected node through one
   `:erpc.multicall` of `Rules.Server.purge_for/1` (a call to that node's Server,
   which runs `Publisher.purge_for/1`), soft-purges the modules it would itself load
   for those hashes, compared with its own published map. A node that missed an
   earlier reload thus checks what it would really load. Going through the Server
   queues the check behind any activation still pending there, including a reload an
   earlier writer stopped waiting for after 10 s (a call's timeout does not cancel
   it), so no load can come between a node's passed check and this write's reload
   there. For that, the reload broadcast sends straight to each Server
   (`GenServer.multi_call/4`) rather than through `:erpc`, whose per-call worker
   process could reach the Server after the next writer's check. Only a reload message
   still in transit on a link stalled for over 10 s could arrive late; that node is in
   practice not answering. Only the lock holder calls other Servers, and a reload
   calls none, so no two Servers wait on each other. If any node answers that a purge
   failed, the write releases the lock and returns `{:error, "rules changed too
   recently; try again"}`: nothing was saved, and the purges that succeeded removed
   only code nothing was running. A node that does not answer within the reload
   timeout (10 s), or answers with an error, is not waited on: its own pre-load purge
   still protects its processes, and if that fails at the reload it is named as
   unconfirmed, like any missed reload. This is a fallback for availability (and for
   an older build mid-deploy); a crash in the purge on a peer is hidden the same way,
   still covered by that peer's pre-load purge.
3. Save, activate locally, ask every connected node to reload, and only then (every
   node answered, or 10 s passed) release the lock. Today the lock is released before
   the local activation and broadcast; holding it keeps the next writer from starting
   while this write's reloads are normally still running. Writers wait at most the
   broadcast's 10 s longer; a contending writer gets
   `:busy` (and the MCP tools retry) as now. Two side effects: a contending writer
   now waits out up to that broadcast, longer than the MCP tools' few seconds of
   retries, so it sees "something else is editing" more often; and if Server crashes
   during the activation or broadcast, the lock stays held until its 120 s lease
   expires, where before it was already released.

So the guarantee is: a too-recent refusal happens before the save and changes nothing
on any node. It covers every node that answered the purge. Residual cases, all
already "a machine that misses the reload": a node that did not answer the purge
within 10 s, or a node whose Server restarted between its check and this write's
reload. Such a node's own
pre-load purge can fail; its reload then fails, it is named as unconfirmed, keeps its
rules, and catches up at the next write, while the write itself succeeds. No retry is
added.

`Publisher` asserts `:code.atomic_load/1` returns `:ok`. A refusal is reachable only
through a bug (something else loading rule modules); it crashes Server, and during a
write, after the save, that leaves the lock held until its 120 s lease expires.

The MCP tools do not retry the too-recent error (it is not `:busy`); the caller sees
the message and can write again.

## Tests

Removed (they exist only for the pool):

- `test/guardian/rules/server_reclaim_test.exs` ("repeated edits reclaim retired
  modules").
- `test/guardian/rules/publisher_test.exs`: "pool reconstruction reserves published
  names and retires unpublished current and old code" and "reclamation keeps a name
  retired while a process executes its old code".
- `test/guardian/rules/server_test.exs`: "an old module stays callable until it is
  reclaimed".
- The namespace test's `Compiler.name(0) == Guardian.Rules.Compiled.M0` assertion.

Changed: publisher_test's compiler-refusal test keeps checking that a refused compile
loads nothing and changes no publication, without pool assertions.

Added:

1. Compiler: `module_name/1` is under the prefix, distinct for distinct tables, and
   raises for an invalid table name.
2. Server (async, own table): a rewrite swaps the table's one module in place, so the
   published module is the same atom and runs the new rules.
3. Server (async, own table): a process held in the table module's old code makes the
   next write fail with the too-recent error, saving nothing (read unchanged, events
   still get the earlier rules); once it finishes, the same write succeeds. The
   holding process runs a small module the test loads under the table's module name
   (a libtest helper), which the first write then replaces, with a message handshake
   and no sleeps. This is a named exception to the testing philosophy's "don't touch
   processes": rules finish in milliseconds, so nothing else can be in old code.
4. Server (async, own table): after a table's rules are all deleted its events pass
   unchanged, and rules written again run (swapping the retained module).
5. Cluster (`:cluster`): the same with the holding process on the peer and the write
   from this node: nothing saved, and both nodes keep the earlier rules.

## Docs

`docs/product/spec.md` 5.1.5 (pool exhaustion removed; the too-recent outcome added),
`docs/architecture/system.md` (rules compilation and publication, module namespace,
the configuration table, the testing summary), `docs/architecture/security.md` (atom
injection, compiled-module literal lifetime), `lib/guardian/rules/AGENTS.md` (module
list, rules to keep 2 and 3), the Rules, Server, Publisher and Compiler module docs,
`libtest/guardian/test/rules.ex`, and TODO.md.

## Expected product spec impact

In 5.1.5: item 4's last two sentences (pool exhaustion) are removed, and item 2 gains
a statement that a write coming while an event on a connected machine is still
running the rules a previous change replaced (milliseconds) fails with "rules changed
too recently; try again", changing nothing; a machine that doesn't answer that check
in time is not waited on and may instead miss the reload. Item 2 also notes the lock
is held until every machine has reloaded or 10 seconds have passed.

Also changed by a test: counter_reload_test's "in-flight old modules keep old state"
assertions go, since old code is no longer callable by name.

## Deploy

No migration and no setting. A rolling deploy mixes old and new nodes briefly: an old
node does not have `Rules.Server.purge_for/1`, so a write from a new node gets an
error from that node's purge call and (treating an error answer like no answer)
proceeds; a write from an old node does not purge on new nodes, whose own pre-load
purge covers it. Every node in a cluster must run the same build (system.md), so this
lasts only for the rollout.
