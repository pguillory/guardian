# Shared Aggregations

Aggregations implement a map-reduce interface shared by query-time GROUP BY and
ingest-time counters:

- `empty/0` for the mergeable state of no rows: an exact identity of `merge`
- `start/N` to build an accumulator from row values
- `merge/2` to combine partial accumulators
- `finish/1` to produce the result

There is no separate default callback: `Guardian.Aggregation.default/1`, a query's
result for no rows, is the finished empty state, and is also a missing or failed
counter's result. Where a natural state cannot serve as the empty one (arbitrary's
state can be a real null; top-N states carry n), use the non-storable atom
`:empty`, which can never be a value.

Register every aggregation name and arity in `lib/guardian/aggregation.ex`. A registry entry is
either a module or `{module, option}`, for one module serving several aggregations
(`Guardian.Aggregation.MinMax` with `:min` or `:max`, `Guardian.Aggregation.Moments` with the variance or
deviation it finishes). For `{module, option}` each callback takes the option first:
`empty(option)`, `start(option, ...)`, `merge(option, acc1, acc2)` and
`finish(option, acc)`. Callers never call a module directly: they get an aggregation
from `Guardian.Aggregation.fetch!/1` and run it with `Guardian.Aggregation.empty/1`,
`default/1`, `start/2` or `start_row/3`, `merge/3` and `finish/2`, the same functions in
the executor, in counters and in `eval_aggregate/2` in tests.

Queries and counters share one behaviour: there is no query/counter option and no
counter opt-in list. Every registered name/arity is a TRACK operator; Rules validate
TRACK against `names_and_arities/0` and resolve configurations once into TRACK steps
and immutable LOOKUP definitions. Counter execution carries those configurations
through empty/start/merge/finish without looking them up again. Count finishes raw:
the int64 limit applies where values are stored. Distinct is Hypex precision
8/Bitstring (256 register bytes); do not change the backend or precision
incidentally. Avg's merge skips empty states, preserving signed-zero bits and
unchanged-write detection. A merge may raise for inputs that cannot combine (top-N
states with different n): queries report the error, and counters fail that
statement open.

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
A list result storage can't hold is null too. `Guardian.Aggregation.finish/2`
owns this check for every list result; callbacks return their constructed or
selected values without revalidating lists. For example, `min_n`, `max_n` and
their `_by` forms produce `nil` when an item is itself a list of lists, since the
result would nest three deep.
Valid lists are returned unchanged. Scalar results pass through verbatim, retaining
each callback's numeric policy (in particular raw counts). This is not a
general scalar storage-validity check. Query column construction and the scalar
expression backstop still validate values at their own boundaries.

Counter states remain plain terms that can be copied through ETS and erpc without
resources or process ownership. HLL registers are fixed size; arbitrary, min/max
and the `_by` forms keep one input, whose bytes depend on that input, and the `_n`
forms keep up to n of them, with no cap on n. Exact count/avg integers grow
logarithmically with accumulated count/sum. These are not strict constant-byte
states. Store's individual payload refusal and asynchronous resident memory target
remain necessary, and value-keeping states can retain sensitive inputs after UNSET.
