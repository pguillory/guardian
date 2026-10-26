# Aggregate list-result validation

Status: implemented and validated.

Superseded in part by [aggregates-unify.md](aggregates-unify.md): separate counter
count bounds, query/counter HLL configurations, defaults/empty states and
counter-only average shortcuts described below were unified afterward. The
list-result validation boundary remains in place; the original compatibility and
validation record below describes this change when it landed.

Product spec impact: none. No statements change in `docs/product/overview.md` or
`docs/product/spec.md`. Supported query and counter results remain unchanged.

## Ownership and compatibility

`Guardian.Aggregation.finish/2` now checks completed list results once with the
existing storage-value validator. A list that storage cannot hold becomes null;
a valid list is returned verbatim. The top-N callbacks only construct their lists,
so `min_n`, `max_n`, `min_n_by` and `max_n_by` no longer duplicate this policy.
Selected lists from min/max, their `_by` forms and arbitrary pass through the same
boundary. Their supported stored/evaluated inputs are already valid. Those lists
now incur one validity scan per finish as well.

This is deliberately a list-result check, not a new scalar normalization policy.
Callbacks still own all numeric behavior: query count and count_if remain raw,
counter count remains int64-bounded, integer sum wraps, and absorbing float
overflow remains null. HLL stays p14/Array for queries and p8/Bitstring for
counters. Query defaults, counter empty states, average's counter-only empty
merge shortcuts and signed-zero bits stay unchanged. No accumulator, registry
configuration, counter key or identity-hash input changes.

Query column construction still validates what columns can store. The scalar
expression backstop in ColumnOrConstant is independent and remains in place.
Neither becomes an unsafe trusted path. Directly injecting invalid list states
into pass-through callbacks is outside the supported input contract; the registry
now nulls those too.

## Validation

Independent Claude and Codex plan reviews approved the list-only boundary.
Direct finish tests cover all four top-N names at the storage depth boundary,
whole-result nulling for mixed-depth values, unchanged bytes in selected lists
through both dispatch forms, empty-list versus no-row results and raw query
count/count_if versus bounded counter count. Existing query numeric tests cover
all four top-N names and grouped SQL reassembly for max_n and min_n_by. Counter
contract/semantics and rule identity tests cover the remaining preserved policies.

Focused aggregation, query, counter runtime and rule identity coverage passed:
179 tests, zero failures. An original-source comparison of all 29 registered
query/counter name/arity configurations matched states and finished results
byte-for-byte through 7,888 single-row and pairwise-merge cases, including nulls,
mixed types, signed zero, int64 boundaries, float overflow and depth-limit lists.

Independent Claude and Codex code reviews approved. Both providers completed all
five concern reviews with the complete diff; a supplemental Claude review corrected
the first Claude helpers' summary-only context. Nonblocking findings added direct
invalid-list coverage for both dispatch forms and clarified the callback-author
documentation. The five finish-boundary tests passed after these adjustments.

The sole full pre-commit passed formatting, warnings-as-errors compilation and
the default suite: 1,229 tests, zero failures, three excluded large tests. No full
run was repeated. No deployment or production verification was performed.
