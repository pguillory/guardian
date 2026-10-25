# Typed counter event context and test backend isolation

Status: implemented and validated.

Product spec impact: none. No statements change in overview.md or spec.md.
Counter keys, identity hashes, routing, results, defaults, TTLs, deadlines and
failed-wait budgets remain unchanged.

Client now returns `Guardian.Counters.Context`, with enforced fields and types
for the shared batch atomics, microsecond deadline and operation allowance,
cooldown table, connected members and store server. Context captures the deadline
before membership. Budget enforces it through existing admission and settlement;
Transport consumes the same fields through a struct boundary. Rules.Event keeps
its private Unix/monotonic arrival coordinates and nests the typed context under
counters on worker entry. Neither context becomes row data.

Transport's compile-time backend defaults to Store. Only the test configuration
selects Guardian.CounterTestBackend, compiled from libtest; that adapter alone
interprets backend/server tuples for mailbox probes and otherwise forwards to
Store unchanged. The selection is internal, not an operator setting or a runtime
switch. Peer tests inherit the compiled module and code paths, so no peer runtime
configuration is required. Production retains direct ETS Store dispatch without
backend tuple interpretation or mailbox fallback.

The remote endpoint's module, arity, operation terms, server and remaining-duration
arguments stay unchanged. No disk migration or deployment is part of this change.

## Validation

Independent Claude and Codex plan reviews approved this scope. Both called out
preserving signed monotonic coordinates, struct-compatible test updates, and
compile-time peer selection. Focused counter and affected rule tests passed with
warnings as errors: 104 tests, zero failures. This includes local/peer mailbox
probes, ordinary Store traffic, deadline/cooldown/cleanup tests, private metadata
and shared budgets through worker replacement, and existing identity/result tests.
New coverage pins the typed context, defaults, shortened deadlines and upper caps.

A dev build compiled with warnings as errors. Inspection of its Transport BEAM
confirmed a direct Store.batch/2 import, no test-adapter import, and no test adapter
on its code path. An isolated unnamed Store round trip through that dev Transport
preserved binary bytes.

Both independent code reviewers approved, each after completing all five concern
helpers. Nonblocking follow-ups clarified deadline ownership and the test-only
store tuple, named the existing time caps and avoided a fresh-membership comparison
in the constructor test. A later shared monotonic-clock helper is recorded in
TODO.md; it is not part of this change. The dev build check and round trip exercise
the production dispatch edge that test builds replace with the adapter; no extra
runtime membership injection was introduced. The affected Context/Budget tests
passed after those refinements: 10 tests, zero failures.

The sole full pre-commit passed staged whitespace, formatting and warnings-as-errors
compilation, followed by 1,218 tests, zero failures and three excluded large tests.
No deployment, production-data writes or hardware verification was performed.
