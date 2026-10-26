# Local store conditional-write and lease races

Status: complete.

Product spec impact: none. These tests pin the existing conditional-write and lease
guarantees; application behavior and the product descriptions do not change.

## Scope

Follow-up to [local-store-lock-id](local-store-lock-id.md) and its folder-identity
fix: race ETag replacements and lease acquisition on a local folder, including
takeover of a released lease. Each race must have exactly one winner per key, all
other contenders must fail, and the stored body and ETag must match that winner.
Keep winners held until every contender has finished, then release them.

The only production writer is still `Guardian.Rules.Server`: it saves/deletes rule
objects and acquires/releases the generic `Guardian.ObjectStore.Lock`. Other Rules
entry points read objects, and Config only constructs stores. Retain the existing
node-local `:global` lock rather than adding a queued lock for a hypothetical writer.

## Contention limit

The backoff described in [local-store-lock-id](local-store-lock-id.md), behavior
item 3, remains: randomized exponential retries cap each delay at 8 s, with no
fairness or total wait limit. A hung write holds up later writes to the same root
folder. A lease acquire timeout bounds retries, but cannot interrupt its underlying
put while that put waits for the local serialization lock. Document these limits
beside the lock and in the local-store module documentation. Revisit a generic
node-local queued lock if another production writer or measured contention needs
one; keep that infrastructure out of Rules.

Overshooting the acquire timeout does not extend the holder's lease deadline: that
deadline is taken before the put begins.

## Validation

- Focused local-store, lease and shared object-store contract tests: 21 passed.
- Regression sensitivity: temporarily replaced the process-specific lock requester
  with the folder identity, making concurrent writers share a requester and bypass
  exclusion. Both new tests failed in all three runs (seeds 0, 1 and 2), reporting
  four successful contenders for one key. The lease test failed in its creation
  round, before reaching released takeover. Restored the process-specific
  requester; no runtime behavior change is included.
- Independent Claude and Codex plan and code reviews approved; each code reviewer
  completed all five concern helpers with the complete diff. Non-blocking feedback
  clarified the mutation result, trimmed duplicated documentation and shared the
  local lease tests' folder setup. No follow-up refactor was warranted.
- The single full pre-commit run passed formatting and warnings-as-errors compile.
  Its suite finished with 1,324 tests, one failure and three exclusions (seed
  196276): an unrelated 1,000 ms segment-start receive timeout in
  `Guardian.Storage.PersistedSegmentsTest`. The local-store and lease races passed.
- A scoped rerun of that storage file and both changed object-store test files
  passed all 19 tests with seed 196276. The storage file also passed with a fresh
  seed (114530). The timeout follow-up is tracked separately; no storage code was
  changed and no second full run was made.
