# Guardian module paths and application name

Status: complete.

Product spec impact: none. Overview impact: none. Reference links in the product
spec follow the moved query-language resource; application behavior is unchanged.
Security architecture impact: none; only source/test paths and the application
supervisor's name change in its references.

## Path alignment

Guardian source now lives under `lib/guardian/`, matching module names. Leaf
utilities live directly there, and `Guardian.Storage.Segment.Registration` lives
under `storage/segment/`. Multi-module files remain whole, including typed rule
steps, generated protocol implementations, and the vendored DistributedStream
Enumerable implementation. Its license and instructions move with it. The small
utilities guide is folded into `lib/guardian/CLAUDE.md`, beside its leaf modules.

Tests mirror their subjects under `test/guardian/`, preserving existing subsystem
grouping and module declarations. Compiled test helpers live in
`libtest/guardian/`, including the query evaluation case and test function in their
matching subdirectories. `test/test_helper.exs` and `test/fixtures/` stay in place.

Paths in documentation, instructions and comments follow the moves. MCP's served
reference stays next to its server; its two direct test readers follow its new
path. Deployment, configuration, golden-fixture and subprocess test lookups retain
the same targets after their relative paths change. Recursive Mix compilation,
formatter and test-discovery paths already include these subdirectories.

## Application callback

The second commit names the application callback `Guardian.Application`, including
the Mix callback, registered supervisor references, documentation and comments.
Child order, restart strategy and startup behavior stay the same.
Operator shell calls that address the application supervisor and diagnostics that
name it now use `Guardian.Application`. Apply the change through a full release
restart, as with the preceding namespace transition.

## Validation

The moves are reviewed separately from the application rename. The path-only tree
passed development and test compilation with warnings as errors and 104 focused
tests (zero failures; one large test excluded), covering MCP resources, deployment,
configuration, golden fixtures and the segment race subprocess. Fixtures and the
test bootstrap were checked byte for byte against the starting tree; no stale exact
file-path references remained.

After the callback rename, 93 focused tests passed with zero failures, covering the
application namespace, counter supervision, rule reloads, stats, ingest retries and
query recorders. No references to the former callback module remained.

The final pre-commit passed formatting, test compilation with warnings as errors
and the full suite on the combined result: 1,174 tests, zero failures and three
excluded large tests. Independent Claude and Codex plan and code reviews approved
both commit partitions. That full run does not independently validate the
intermediate path-only commit.

## Test-name follow-up

Product spec impact: none. Overview impact: none.

The 38 remaining legacy test module declarations now include the subsystem in their
paths, including AST nodes/operators, parsing/tokenizing, configuration, storage and
the JSON API. The not-operator test's old `NoOperatorTest` spelling is corrected at
the same time. Test bodies, discovery paths and fixtures are unchanged.

Validation: all 38 changes are declaration-only, every target module name is unique,
and no old-name references remain in source, helpers, tests or docs. The combined
follow-ups passed 317 focused tests with zero failures (three large tests excluded).

Final combined checkpoint: independent Claude and Codex plan and code reviews
approved; the full pre-commit passed formatting, compilation with warnings as
errors and 1,194 tests with zero failures (three large tests excluded).
