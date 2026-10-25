# Query scalar/native dispatch policy

Status: implemented and validated.

Product spec impact: none. No statements change in `docs/product/overview.md` or
`docs/product/spec.md`. Query results, null/error handling and coercions remain
unchanged. Aggregates are outside this change.

## Ownership and compatibility

Native callback selection and eligibility live in `Guardian.Query.ColumnOrConstant`.
Operators and conversion functions identify their operation and supply their scalar
callback; the shared policy keeps constants on the scalar path and uses the existing
native path only for eligible columns.

Preserve timestamp arithmetic's existing metadata rules: addition checks string and
integer presence in either direction; subtraction checks only strings on the left
and integers on the right. Preserve `to_string`'s native identity path for columns
holding only strings and nulls. Other values still use the capped scalar renderer.
The existing map/native result normalization and count checks stay in place.
AND/OR keep their lazy right-operand evaluation, and comparisons keep their separate
range shortcuts. Scalar numeric and text semantics do not move.

The policy lives beside the existing representation/dispatch machinery so callers
have one boundary for both eligibility and column/constant handling. Scalar callbacks
remain parameters; the policy does not depend on AST or function modules. Unknown
operations fail loudly. Existing generic `map_or_nif` arities remain available.

Evaluation's alias blocks are consolidated as the already tracked adjacent tidy-up.

## Validation

Independent Claude and Codex plan reviews approved. Focused policy, affected
operator/function, registry, Evaluation and totality coverage passed with warnings
as errors: 74 tests, zero failures. Direct policy tests use sentinel scalar callbacks
to check native selection, timestamp metadata directionality, top-level type checks,
strings/nulls identity, constants, empty inputs, count errors and unknown operations.
An unreachable raising right operand also checks AND/OR laziness.

An original-source comparison against revision `a144abe` passed 75,204 cases across
all nine affected operations. It compiles renamed copies of the original shared
machinery and operator/function modules, calling original protocol implementations
directly because test protocols are consolidated. Each changed node is compared at
the top level; its unchanged identifier/literal operands use the existing evaluator.
It covers packed and mutable input columns, zero/one/multiple rows, both constant
positions and all-constant operands, mixed types, nulls, int64 bounds/wrapping,
signed zero, float overflow/divide-by-zero, valid/invalid/boundary timestamps, lists,
invalid UTF-8 and strings past the cap. Count-mismatch errors are compared too;
unexpected baseline errors fail the harness.

Constants and caught errors compare as Erlang external-term bytes. Native resource
results compare their packed content while retaining a distinct resource-kind tag;
packed results compare directly. This checks result representation as well as values
without mistaking a NIF resource's unique reference for its content. The harness is
external validation, not a runtime or test dependency on Git history.

Independent Claude and Codex code reviews approved after each provider completed
all five per-concern helper reviews with the complete diff. Nonblocking feedback
clarified the policy documentation and dynamic-invalid-operation test, and added
direct mutable-column coverage. Possible extraction of the operation policy and
narrowing of generic helper visibility is recorded separately in TODO.

The nine policy tests passed with warnings as errors after these adjustments.
The sole full local pre-commit passed formatting, warnings-as-errors compilation
and the default suite: 1,238 tests, zero failures, three excluded large tests.
No full run was repeated. No deployment or production verification was performed.
