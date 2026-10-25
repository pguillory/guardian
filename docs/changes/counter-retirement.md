# Retire obsolete counter entry points

Status: implemented and validated.

Product spec impact: none. No statements change in overview.md or spec.md.
TRACK/LOOKUP semantics, query results, aggregate policies, states, fail-open
behavior, deadlines, cooldowns and budgets remain unchanged.

The batched key machines introduced in [counter-batching.md](counter-batching.md)
are the only counter client path. The legacy scalar Cluster methods and their
single-call plumbing are removed. Cluster's remote endpoint accepts only owner
pipelines. Store retains the atomic get/gets/cas/incr primitives used by its
ordered batch executor; its obsolete multi-key read API is removed. Existing
transport, failure-budget, cooldown and helper-cleanup tests now use pipelines.

Rules resolve explicitly opted-in shared aggregate configurations after semantic
validation, once during plan construction. TRACK steps, immutable LOOKUP target
definitions, compiled plan metadata and key machines carry those configurations
through `Guardian.Aggregation.empty/start/merge/finish`. The thin counter aggregate
adapter from [shared-aggregates.md](shared-aggregates.md) is removed. Unsupported
operators retain the same validation errors. The name/arity tuple remains for
diagnostics and native-count dispatch; the newly derived configuration is excluded
from dependent plan hashes, preserving their original struct-shaped hash input.
Canonical TRACK identities, stored states and owner selection are unchanged.

Counter numeric/default/signed-zero/HLL tests now exercise the shared API directly.
Regression coverage checks configuration binding and compiled-plan recovery for
every operator, and reproduces the previous dependent-plan hash construction.

Validation: both independent plan reviewers approved. The focused counter,
rule, shared-aggregation and query-language run executed 285 tests with zero
failures, but warnings-as-errors rejected a direct call to the test's generated
module. Calling that generated metadata dynamically removed the warning; the
affected plan/runtime tests then passed (55 tests). Both independent code reviewers
approved after all five concern helpers completed for each provider. Nonblocking
cleanups clarified documentation and plan construction, and added malformed-input
and batch-only endpoint coverage. The affected focused tests passed (76 tests).
The sole full pre-commit run then passed formatting, warnings-as-errors compilation
and the default suite: 1,184 tests, zero failures, three excluded large tests.

The separate Cluster client/facade split remains deferred. No deployment or
production verification is part of this change.
