# Native dispatch boundary

Status: implemented.

Product spec impact: none. No statements change in `docs/product/overview.md` or
`docs/product/spec.md`. Query results, null/error handling and coercions remain
unchanged. Security architecture: none.

## Problem

The scalar/native operation policy from `query-dispatch-policy.md` lived inside
`Guardian.Query.ColumnOrConstant`, the column/constant representation layer, which
also exposed generic `map_or_nif/3,4,5` helpers and `holds?/2` that nothing outside
it used. The ternary `map_or_nif/5` had no callers at all.

## Ownership and compatibility

`Guardian.Query.NativeDispatch.evaluate/3,4` now owns scalar/native selection for
arithmetic, boolean operations, `to_boolean` and `to_string`. Its clauses, guards,
clause order, metadata rules and callbacks are moved unchanged: constants keep the
scalar path, addition checks timestamp/seconds metadata in either direction,
subtraction checks only strings on the left and integers on the right, and native string
conversion applies only to string/null columns. Unknown operations still raise
`FunctionClauseError`, and constant/column count mismatches still fail in
`ColumnOrConstant.map`.

The unary and binary constant-or-native helpers and the metadata `holds?` check are
private to NativeDispatch. `ColumnOrConstant` no longer has `evaluate/3,4`,
`holds?/2` or `map_or_nif/3,4,5`; the ternary form is removed. Its representation and
mapping API is otherwise unchanged. NativeDispatch depends on ColumnOrConstant,
Constant and Storage.Column, not on AST or function modules. A new native-backed
operation gets an `evaluate` clause there rather than its own helper.

The seven native-backed operators and `to_string`/`to_boolean` call NativeDispatch
with unchanged arguments. AND/OR keep lazy right-operand evaluation and their
ColumnOrConstant metadata checks. The direct policy tests move to
`test/guardian/query/native_dispatch_test.exs` with unchanged assertions.

## Validation

Independent Claude and Codex plan reviews approved the extraction and module name,
and agreed that a new external equivalence harness is unnecessary for a mechanical
move of the policy that `query-dispatch-policy.md` already compared against the
original source.

Focused policy, affected operator/function, totality, registry and Evaluation
coverage passed with warnings as errors: 32 tests, zero failures. Independent Claude
and Codex code reviews approved after each completed all five per-concern helper
reviews of the complete diff. Nonblocking feedback sorted the test aliases and
clarified the architecture and change-document wording. The sole full local
pre-commit run passed formatting, warnings-as-errors compilation and the default
suite: 1,261 tests, zero failures, three excluded large tests. No deployment or
production-data verification was performed.
