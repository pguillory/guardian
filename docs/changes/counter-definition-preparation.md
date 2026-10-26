# Prepare counter definitions once

Status: implemented and validated.

The duplicate TRACK fields and stored aggregate configurations described below
were subsequently removed by
[counter-definition-single-source.md](counter-definition-single-source.md).
Definitions are now built with parsed TRACKs and checked before plan construction;
execution selects the shared aggregate by name. Hash inputs remain unchanged.

Product spec impact: none. No statements change in overview.md or spec.md.
Counter identities, bucket keys, results, aggregate defaults, ordering, budgets
and reload selection remain unchanged.

Runtime previously rebuilt a CounterDefinition for every TRACK on every event,
and Resolution selected the legacy hash fields itself.

After semantic validation, RuleSet resolves each TRACK's aggregation configuration
and builds its immutable CounterDefinition. TRACK steps retain that definition;
Resolution binds the same metadata into LOOKUP targets, and Runtime selects it
directly rather than constructing a definition for each event. Parsed TRACKs have
no definition until validation succeeds. Existing flat TRACK fields remain to
keep this refactor narrow. Compiled plan recovery preserves definitions in both
flat steps and execution levels. The existing full-release-restart model applies;
this does not add support for hot-loading a new Runtime beside old generated plans.

CounterDefinition.hash_term/1 owns the legacy hash field selection. It preserves
the original struct marker, identity, operator, window_ms, bucket_ms and group_arity;
derived aggregation configuration stays excluded. Resolution retains the same
target order, base digest, term serialization and SHA-256 encoding.

Regression coverage captures hardcoded counter identity and base-plan digests
before the refactor for TRACK-only, local LOOKUP, grouped cross-table LOOKUP and
multiple-target plans. Those tests also reconstruct resolved hashes independently
with the legacy struct-shaped target maps. The baseline tests passed against the
old implementation before production files changed. Every supported aggregate
checks prepared candidate definitions, exact compiled-plan recovery, both step
representations and byte equality between hash_term and the old Map.delete input.

Resolved hashes are compared within the same VM: the existing ETF map encoding
can order atom keys differently with VM atom load order. Stabilizing hashes across
VM starts is separate work; changing that encoding here would change existing
hashes. This refactor preserves it. Counter identity digests do not use map encoding.
(Superseded by `plan-hash-determinism.md`.)

No deployment or production verification is included.

Validation: independent Claude and Codex plan and code reviews approved. Both code
reviewers completed all five concern helpers. Focused plan, runtime, reload,
ingestion, RuleSet and Counters coverage passed: 152 tests, zero failures, with
warnings as errors. Small nonblocking review findings clarified documentation and
the preparation invariant, and strengthened the baseline target-identity assertion.
The affected plan tests then passed: 29 tests, zero failures. The sole full
pre-commit passed formatting, warnings-as-errors compilation and the default
suite: 1,215 tests, zero failures, three excluded large tests.
