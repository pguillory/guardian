# Counter merge order is not a promise

Status: implemented.

Product spec impact (`docs/product/spec.md`):

- 5.1.4 item 1 loses "Min/max ties keep the later merged value, including its type."
- Section 7 item 4 gains: which of tied values `min`, `max` and the `_by` forms
  return is undefined (1 or 1.0, for example); in the `_n` forms so are the order of
  tied values and which of them a limit of n keeps. A float `sum`, `avg`, variance or
  standard deviation can depend on the order partial results merge in: usually only
  in its last bits, but more when large values cancel, an overflow can give null
  where another order would not, and an integer sum can wrap before a float joins it.

## Problem

Counter execution combined a statement's bucket states oldest to newest, with the
written current bucket last, so that min/max ties kept the newer value and its type
and float sums kept one fixed order. The spec promised the tie rule. Nothing else
depends on that order, and the promise stands in the way of merging states in any
order.

## Change

Ties are undefined, as in SQL, for queries and counters alike. Order-sensitive
float results may vary with merge order; Guardian does not round or truncate them.
Execution still writes the newest bucket and reads the others, but the order it
combines them in is no longer a contract. The aggregation code is unchanged, so
results today are unchanged.

Checked and unaffected: read-your-write (the write's merged state is one of the
combined states, wherever it sits), LAST windows (buckets are chosen by arrival
time), `arbitrary` (already "any one value"), the best-first order of non-tied `_n`
values, count, count_if, all, count_distinct, all-integer sum and avg, and
unchanged-write detection before CAS.

This supersedes the order statements in `shared-aggregates.md` (right-biased ties),
`counter-execution-topdown.md` and `counter-batching.md` (current bucket last), and
`ingest-rules.md` (right-biased ties, including the winning numeric type).

## Validation

Tests no longer pin a tie winner: they accept either tied value, or the tied values
in either order. Variance and standard deviation results are checked within a
small tolerance. The CAS regression for a numeric type change uses a sum
(1 plus 0.0) instead of a min/max tie, and the bucket test uses older values that
decide the result, so it still shows older buckets are combined. A counter's
`arbitrary` result is checked as one of its inputs, and its `var_pop` within a
tolerance.
