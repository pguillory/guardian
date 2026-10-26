# Query Functions

For dispatch mechanics, worked implementation patterns, utilities and test examples,
see the [query function guide](../../../../docs/guides/query-functions.md).
This file holds the editing rules.

## Registration and evaluation

- Each function has one `Guardian.Query.Function.FunctionName` module in its
  snake_case file. Manually register every name and arity in
  `lib/guardian/query/function.ex`; names are lowercase, queries case-insensitive.
  Aliases register the same module under additional names.
- The default evaluation maps `eval/N` over arguments in order (arities 1–4);
  without `eval2/2`, provide one scalar `eval/N` for every registered arity.
- Define `eval2(context, %Guardian.AST.Node.FunctionCall{})` only when the default
  is insufficient: short circuits, literal compilation, native paths, rewrites or
  constants. It returns a `ColumnOrConstant` Column or Constant, evaluates arguments
  through `Guardian.Query.Eval.eval/2`, and handles every registered arity.
  Match on arguments, never `name:`, so aliases work.
- Without `eval2/2`, a zero-argument `eval/0` runs once per row. A deterministic
  constant should define `eval2/2` with `Constant.duplicate/2` and
  `Evaluation.context_count/1`. Add non-deterministic functions to
  `Guardian.Query.Evaluation.@non_deterministic_functions` so the test-only
  `pre_eval/1` does not fold them; runtime queries do no compile-time folding.
- Use `ColumnOrConstant.map`, not `Enum.map`, for column/constant values.
  Variable-arity functions evaluate every argument and use `map_n/2` for one call
  over each row's values. Never fold a capped string join through nested binary
  calls: `Text.form_cut/2` must see the whole join and stop at its first cut.
- Native-backed operations call `Guardian.Query.NativeDispatch.evaluate/3,4`
  with the operation and scalar callback. NativeDispatch owns selection and
  eligibility; add new operation clauses there, not a local native helper.
- Keep scalar evaluation simple and avoid allocations in tight loops. Preserve
  metadata-based short circuits (`if`, `coalesce`) to skip unused branches.

## Totality

Every function and operator returns a storable value or `nil` for every input,
never raising or returning a bignum, non-finite float, a list deeper than a list
of lists, or a built string over 64 KiB.

- Guard expected types and provide a fallback clause returning `nil`.
- Wrap integer results to int64 with `Guardian.Query.Numeric.wrap/1`, matching
  native arithmetic. Catch `:error, :badarith` for float overflow and return `nil`.
  Invalid arithmetic/domain results and rounded floats outside int64 are `nil`
  (`Numeric.int64_or_nil/1`).
- Cap built strings with `Guardian.Query.Text.cap/1`, or stop at
  `Text.max_bytes/0`. Returning an input or a slice needs no cap; transforming
  an input (`replace`, `lower`) does, even without growth.
  Convert values through `Text.form/2`, never `Kernel.to_string/1`.
  Joins stop at the first piece cut by `Text.form_cut/2`.
- Parse URLs through `Guardian.Query.URL.parse/1`, never `URI.parse/1`;
  the shared nonraising helper never converts a port longer than 20 digits.
- `ColumnOrConstant.list_or_constant_to_column_or_constant/1` replaces remaining
  unstorable results with `nil`; this backstop does not replace these rules.
- Compile and execute query regexes only through `Guardian.Query.Regex`
  (`:re` with mandatory `match_limit` and `match_limit_recursion`).
  Never call `:re` directly from a function; the fixed copies of URI patterns
  inside `Guardian.Query.URL` are the sole exception and run no user pattern.
  Never reintroduce a regex NIF: Hyperscan aborted the VM on growing/overlapping
  matches. There is no `jq()`; the parser rejects it.

## Tests

Add a test file under `test/guardian/query/function/` using
`Guardian.Query.EvaluationTestCase` for each function; cover valid, invalid and
wrong-type inputs. `Guardian.Query.FunctionRegistryTest` exercises every
registered name, including aliases.
`test/guardian/query/totality_test.exs` exercises every registered function and
operator per event, on constants and over columns, checking agreement.
Add edge values for new input kinds; values too large for its pairwise grid go
in `@huge_values`, tested alone against every function.
