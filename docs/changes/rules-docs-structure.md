# Rules documentation structure

Status: implemented and validated.

Product spec impact: overview none. Section 5.1 of `docs/product/spec.md` gains
numbered subsections for Files, Statements, Running, Counters, Writing and Startup.
Contract prose and list item numbers are unchanged. Runtime behavior is unchanged.

## Invariants

The former Rules invariant 8 is now nine single-purpose requirements, numbered
8–16: contextual words, whole-set preparation, compiler admission, coherent
reload/restart recovery, shared counter responsibilities, counter failure policy,
sensitive counter state, event retry/rollback policy and memory configuration.
Invariants 1–7 retain their numbers and text. The reviewed-design requirement still
applies to all counter semantics.

The coherent-reload reference in [the ingest-rules history](ingest-rules.md#compilation)
now names invariant 11. The [Rules instructions](../../lib/guardian/rules/CLAUDE.md#rules-to-keep)
remain the implementation requirements' home.

## Spec links

The new subsection anchors are:

- [5.1.1 Files](../product/spec.md#511-files)
- [5.1.2 Statements](../product/spec.md#512-statements)
- [5.1.3 Running](../product/spec.md#513-running)
- [5.1.4 Counters](../product/spec.md#514-counters)
- [5.1.5 Writing](../product/spec.md#515-writing)
- [5.1.6 Startup](../product/spec.md#516-startup)

Topic-specific references in the guide, subsystem instructions and historical
change notes link to those subsections. Broad links to [section 5.1](../product/spec.md#51-rules)
remain valid. Historical notes retain their item references; previously ambiguous
references in the aggregate and total-function changes are disambiguated against
the spec at those changes' commits. No code comments cited the old invariant or
needed a new section target.

## Validation

Independent Claude and Codex plan reviews approved. Local checks passed for 159
scoped relative links and heading fragments. Reversing only the new spec headings
reproduces the previous spec byte for byte; invariants 1–7 are unchanged and the
invariant list runs consecutively through 16. The obsolete invariant citation is
gone. `mix format` and whitespace checks passed.

Independent Claude and Codex staged-diff reviews approved, each using all five
concern helpers. Nonblocking wording clarifications scope the retry/rollback
invariant to rule execution and counter updates, retain the division of counter
responsibilities and point readers to follow-up counter designs.

The sole full pre-commit passed formatting, warnings-as-errors project compilation
and the default suite: 1,322 tests, zero failures, three large tests excluded. No
full run was repeated. After recording the result, scoped link and whitespace
checks passed again. No deployment or production verification was performed.
No behavior tests are added for this documentation-only change. No deployment or
production verification is part of this work.
