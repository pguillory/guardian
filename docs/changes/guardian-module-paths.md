# Guardian module paths and application name

Status: path moves complete; application callback rename pending.

Product spec impact: none. Overview impact: none. Reference links in the product
spec follow the moved query-language resource; application behavior is unchanged.

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

The following commit will rename `Guardian.Main` to `Guardian.Application`,
including the Mix callback, registered supervisor references, documentation and
comments. Child order, restart strategy and startup behavior stay the same.

## Validation

The moves are reviewed separately from the application rename. The path-only tree
passed development and test compilation with warnings as errors and 104 focused
tests (zero failures; one large test excluded), covering MCP resources, deployment,
configuration, golden fixtures and the segment race subprocess. Fixtures and the
test bootstrap were checked byte for byte against the starting tree; no stale exact
file-path references remained.

One final pre-commit checks formatting, test compilation with warnings as errors
and the full suite on the combined result, after independent plan and code review.
That full run does not independently validate the intermediate path-only commit.
