# Rules and idempotency documentation ownership

Status: implemented and validated.

Product spec impact: none. No statements change in `docs/product/overview.md` or
`docs/product/spec.md`; their intentionally overlapping product tiers remain intact.
Runtime behavior is unchanged.

## Ownership

- [Product spec section 5, item 9](../product/spec.md#5-ingestion) owns the public
  idempotency contract; [section 5.1](../product/spec.md#51-rules) owns rule behavior.
- [The API reference](../reference/api.md#retrying-a-batch) keeps interface examples
  and client retry guidance. The [rules guide](../guides/rules.md) keeps worked
  examples, safe editing steps and store setup, with links for detailed semantics.
- [Rules instructions](../../lib/guardian/rules/CLAUDE.md#rules-to-keep) (with a
  heading added for direct links) and
  [Web instructions](../../lib/guardian/web/CLAUDE.md) own mandatory implementation
  requirements. The [ingest architecture](../architecture/system.md#3-ingest-path)
  describes the mechanisms, including coordinator lifecycle and rule compilation.
- [The rules change](ingest-rules.md) preserves phase plans, decisions and validation
  history, explicitly distinguished from the current contract. Repeated compilation
  requirements and the store-switch runbook now link to their current homes.
  [The idempotency change](ingest-idempotency.md) preserves intent, design rationale
  and validation history, linking to current behavior and implementation rules.

The rules guide and Web instructions no longer repeat the detailed counter and
idempotency contracts. Actionable warnings and coordinator privacy/cleanup rules
remain at the point of use. Existing headings and numbered historical sections
are retained for inbound links and prose references.

[Aggregate finish](aggregation-finish.md) and
[counter retirement](counter-retirement.md) now point out the policy changes in
[aggregate unification](aggregates-unify.md). Their original implementation and
validation history remains intact; list-result validation and obsolete-entry-point
removal are still valid.

## Validation

Independent Claude and Codex plan and staged-diff reviews approved. Each code
reviewer completed all five concern helpers. Nonblocking review findings restored
historical compiler details, made the receipt-only counter retry warning explicit,
and retained the coordinator's prohibition on evicting pending claims.

A temporary local script checked edited Markdown files' relative links and heading
fragments, including inbound links from tracked Markdown. Existing headings are
retained; historical numbered prose references were checked by hand. The overview
and full product spec are unchanged.

The sole full pre-commit passed formatting, warnings-as-errors project compilation
and the default suite: 1,306 tests, zero failures, three large tests excluded. No
full run was repeated. No deployment or production verification was performed.
