# Shared Aggregations

Aggregations implement a map-reduce interface shared by query-time GROUP BY and
ingest-time counters:

- `default/0` for the final result of an empty query
- `start/N` to build an accumulator from row values
- `merge/2` to combine partial accumulators
- `finish/1` to produce the result

Counter configurations implement `empty` instead of `default` for an empty mergeable state. This
is separate from `default`, which is the final empty query result: sum defaults
to 0.0 for an empty query but its counter empty state/result is nil.

Register every aggregation name and arity in `lib/guardian/aggregation.ex`. A registry entry is
either a module or `{module, option}`, for one module serving several aggregations
(`Guardian.Aggregation.MinMax` with `:min` or `:max`, `Guardian.Aggregation.Moments` with the variance or
deviation it finishes). For `{module, option}` each applicable callback takes the option first:
`default(option)`, `start(option, ...)`, `merge(option, acc1, acc2)`,
`finish(option, acc)` or the counter-only `empty(option)`. Callers never call a module directly: they get an aggregation
from `Guardian.Aggregation.fetch!/1` and run it with `Guardian.Aggregation.default/1`, `start/2` or
`start_row/3`, `merge/3` and `finish/2`, the same functions in the executor and in
`eval_aggregate/2` in tests.

Counters use the explicit name/arity opt-in list in `Guardian.Aggregation` through
`fetch_counter!/1`; `counter_operators/0` derives the fixed v1 allowlist from it.
The existing per-aggregate modules own all logic. `Guardian.Counters.Aggregate`
only validates arity and translates its API to empty/start/merge/finish. Do not
add an operator implementation there or automatically expose query aggregates to
counters. Assess state growth and transport before adding an opt-in.

Preserve the configured differences: Count uses explicit :query/:counter contexts
(including count/0) and applies int64 output bounds only for counters. Distinct uses
Hypex precision 14/Array for queries and precision 8/Bitstring (256 register bytes)
for counters. Do not change Hypex backends or precision incidentally. Avg's counter
mode skips empty states after overflow handling, preserving signed-zero bits and
unchanged-write detection; its query mode keeps the existing arithmetic merge.

The min and max families share `Guardian.Aggregation.Ordering` (the comparison, where a tie goes
to the second accumulator, the `n` check and the matching-`n` merge), and the `_n` forms
keep their best `n` with `Guardian.Query.Sorting.merge_take/4`.

Design merges for combining partial results across segments and nodes. Floating-point
rounding/cancellation, absorbing overflow and integer wrapping mixed with floats
can make regrouping change a numeric result; do not claim universal associativity.
Test empty, null, mixed-type, and multi-segment behavior as applicable.

Aggregates follow `Guardian.Query.Numeric` like scalar functions. An integer `sum` wraps to
int64. A float overflow in `merge` (`:error, :badarith`) makes the state `:overflow`,
which absorbs every later merge, so the overflow survives merging across segments and
nodes, and `finish` turns it into `nil` (`sum`, `avg`, `Guardian.Aggregation.Moments`). Don't
let an overflowed state look like an empty one: an empty group can finish to a value.
A result storage can't hold is null too: `min_n`, `max_n` and their `_by` forms
finish as `nil` when an item is itself a list of lists, since the result would nest
three deep.

Counter states remain plain terms that can be copied through ETS and erpc without
resources or process ownership. HLL registers are fixed size; min/max keep one
input, whose bytes depend on that input. Exact count/avg integers grow logarithmically
with accumulated count/sum. These are not strict constant-byte states. Store's
individual payload refusal and asynchronous resident memory target remain necessary.
