# Query Aggregations

Aggregations implement a map-reduce interface for query-time GROUP BY execution:

- `default/0` for an empty input
- `start/N` to build an accumulator from row values
- `merge/2` to combine accumulators associatively
- `finish/1` to produce the result

Register every aggregation name and arity in `lib/aggregation.ex`. A registry entry is
either a module or `{module, option}`, for one module serving several aggregations
(`Aggregation.MinMax` with `:min` or `:max`, `Aggregation.Moments` with the variance or
deviation it finishes). For `{module, option}` every callback takes the option first:
`default(option)`, `start(option, ...)`, `merge(option, acc1, acc2)`,
`finish(option, acc)`. Callers never call a module directly: they get an aggregation
from `Aggregation.fetch!/1` and run it with `Aggregation.default/1`, `start/2` or
`start_row/3`, `merge/3` and `finish/2`, the same functions in the executor and in
`eval_aggregate/2` in tests.

The min and max families share `Aggregation.Ordering` (the comparison, where a tie goes
to the second accumulator, the `n` check and the matching-`n` merge), and the `_n` forms
keep their best `n` with `Query.Sorting.merge_take/4`.

Merge must be associative because partial results are combined across segments and
nodes. Test empty, null, mixed-type, and multi-segment behavior as applicable.

Aggregations are query features only; there is no ingestion-time aggregation runtime.
