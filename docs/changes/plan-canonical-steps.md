# One canonical Rules.Plan step representation

Status: implemented and validated.

Product spec impact: none. No statements change in overview.md or spec.md.
Execution order, results, counter identities, hashes, bucket keys and activation
retention remain unchanged.

## Problem

A resolved `Guardian.Rules.Plan` carries its typed steps twice: `steps`, the
deterministic flat metadata order (the greedy Kahn order with LOOKUP ancestors
first and UNSETs last), and `levels`, the dependency levels execution runs.
Resolution rebuilds `levels` from the bound steps, and Compiler embeds the
levels once and reconstructs the flat order from compile-time positions
(`docs/changes/rules-compiler-metadata.md`). Two copies of the same data in one
value can drift, and every consumer has to know which field is authoritative.

## Change

`steps` is the one canonical representation. `levels` leaves the Plan struct.

1. Execution levels are a pure function of the flat steps
   (`Guardian.Rules.DependencyGraph.levels/1`). Resolution no longer stores them;
   Compiler calls the same function on the same bound flat list Resolution used,
   so the compiled levels are identical to today's.
2. Compiler derives the levels from `plan.steps` once at compile time, embeds them
   as the one escaped literal (unchanged), and still records each flat step's
   position in the flattened levels. Generated `plan/0` rebuilds the flat steps
   from those positions, so the recovered plan equals the compiled plan exactly
   (now with no `levels` field). `apply/2` passes the embedded levels to
   `Runtime.run/3` as today: no per-event graph construction.
3. The base and resolved hashes are computed from the flat steps only, as today,
   so every pinned hash is byte-identical. Flat metadata order is untouched.
4. Tests and helpers that read `plan.levels` derive levels from `plan.steps`
   through `DependencyGraph.levels/1`. Docs (Plan moduledoc, Compiler moduledoc,
   `lib/guardian/rules/AGENTS.md`, `docs/architecture/system.md`) say the plan
   holds only flat steps and levels are compile-time derived.

Levels are now derived only for tables that actually compile (new, or with a changed hash), not
for every resolved table on every activation. A dependency cycle, which validation
already makes unreachable, would now surface as a compile failure for that table
rather than a raise during resolution.

Rejected alternative: making levels canonical and storing the flat order as
positions in the Plan. Hashes, Activation, Resolution and validation tests all
read the flat order, and positions are an encoding detail of the generated
module, so the plan would become harder to read for no gain.

## Validation

The focused rules suite (`test/guardian/rules/`, with warnings as errors) passed:
156 tests, zero failures. It covers the pinned hash and identity baselines, exact
plan recovery when the two orders differ (now also checking that the recovered
plan has no `levels` field), empty plans, both generated entry points, the
all-aggregate recovery round trip, reload/restart recovery and Server redaction.
Independent Claude and Codex plan reviews approved. Independent Claude and Codex
code reviews approved, each with all five concern helpers; nonblocking fixes
tightened wording, reflowed docs and dropped test assertions made redundant by
exact recovery.
