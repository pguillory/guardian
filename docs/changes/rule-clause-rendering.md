# Rule clause rendering ownership

Status: implemented and validated.

Product spec impact: none. No statements change in `docs/product/overview.md`
or `docs/product/spec.md`.

SET, UNSET, TRACK and LOOKUP share an internal AST statement rendering
helper, `Guardian.AST.Node.Statements.RuleClauses`, for optional BY and WHERE
clauses. Statement modules no longer call another statement's rendering
helpers. LOOKUP keeps its private FROM renderer; SELECT rendering is out of scope.

The existing renderers moved unchanged, preserving omitted clauses, spaces,
comma separators, expression rendering and clause order byte for byte. Parsing,
traversal, canonical source, counter identities, plan hashes and execution stay
unchanged.

Existing parser tests pin optional-clause combinations and canonical source;
counter plan tests pin identities and hashes. Round-trip coverage now includes
literal false/null predicates for all four rule statements and LOOKUP combining
FROM, multiple BY expressions and WHERE.

The focused AST rule parser, AST traversal, Rules counter plan and Rules rule set
files passed before and after the extraction: 65 tests, zero failures in each run,
with warnings as errors. The added canonical-source cases passed against both
implementations, and fixed counter identity and plan hash baselines stayed intact.

Independent Claude and Codex plan and code reviews approved. Both code reviewers
completed all five concern helpers; neither identified a later refactor. Minor
documentation and helper-comment suggestions were incorporated after review.

The sole full pre-commit passed formatting, warnings-as-errors compilation and
the default suite: 1,309 tests, zero failures, three excluded large tests.
No deployment or production verification is included.
