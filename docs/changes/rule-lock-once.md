# rule-lock-once: try the rule write lock once; retry briefly only in the MCP tools

Status: complete.

## Problem

`Guardian.ObjectStore.Lock.acquire/4` polled a held lock every 500 ms for up to 10 s,
and `Guardian.Rules.Server` called it inside its `handle_call`. A contended write or
delete therefore held the node's rule server for up to 10 s, during which its reloads
waited too (so a peer's 10 s reload broadcast could report the node unconfirmed), and
the busy test in `test/guardian/rules/server_test.exs` spent 10 s waiting.

The wait covered only one case: another node mid-write, which takes seconds (a list,
fetching changed files, preparing the set twice and one save with a 20 s deadline).
It never covered a lock left behind by a crashed holder or by a write whose outcome
was unknown: those stay held until their 120 s lease runs out by the store's clock,
far past 10 s, so those writes already failed as busy after waiting.

## Behavior

1. `Lock.acquire/4` makes one attempt. Its only option is `:lease_ms`; `:timeout_ms` is
   gone (nothing outside tests passed it). A live lock, a lock that vanished between
   the failed create and the read, and a takeover another contender made first all
   return `{:error, :busy}`. Nothing in the lock layer waits or retries. A local-folder
   store's put can still wait for that folder's own `:global` lock, as before.
2. `Rules.write_rule/3` and `Rules.delete_rule/2` return `{:error, :busy}` when the lock
   is held, having changed nothing. Rules has no retry either.
3. The MCP `write_rule` and `delete_rule` tools, the edge, call again after 0.5, 1 and
   1.5 s on busy (about 3 s of waiting), stopping at the first other result. Retrying
   the whole call is safe because busy means nothing was changed, and each attempt
   re-reads and re-validates the store. Then the tool error is: "something else is
   editing the rules, so nothing was changed; try again in a few seconds (a lock left
   by an interrupted write expires within 2 minutes)". The retry waits in the
   request's task, not the rule server; requests within one MCP session run one at a
   time, so that session's next call waits behind it, while other sessions do not.
   A cancelled call between retries just stops.
4. Two writes on different nodes that overlap: the loser now sees busy (at the MCP
   tools, after the short retry, usually saved or rejected instead), where it used to
   wait inside the rule server.

Unchanged: the 120 s lease and its takeover, the 80 s save margin, the unknown-outcome
rule (leave the lock to expire), ownership-safe release, and the local folder lock.

## Product spec impact

`docs/product/spec.md` 5.1 item 2.

Before:

> 2. Writes take a lock held in the store itself, so they are serialized across every
>    machine, then every connected machine reloads. Machines also re-read the store
>    every minute, catching changes made directly in the store.

After:

> 2. Writes take a lock held in the store itself, so they are serialized across every
>    machine, then every connected machine reloads. If the lock is held when a write or
>    delete tries to take it, the operation fails without changing anything; the MCP
>    tools try again for a few seconds, then report that something else is editing the
>    rules. A lock left by an interrupted write expires within two minutes. Machines
>    also re-read the store every minute, catching changes made directly in the store.

## Validation

1. `lock_test`: a busy acquire makes one create and one read; the vanished-lock and
   lost-takeover paths are busy after one try (FakeS3 faults, no timing).
2. `server_test`: a held lock makes a write fail as `{:error, :busy}` after one create
   and one read, with no wait.
3. `rules_tools_test`: with the retry delays set to 0 ms through
   `:mcp_rule_busy_retry_delays_ms`, a held lock gives the tool error after three
   attempts; a busy first attempt then saves on the retry; a busy delete stops at its
   first other error. No sleeps.
4. `cluster_test`: the cross-node conflict is pinned sequentially (rejected), and the
   concurrent race accepts busy or rejected for the loser.
