# total-functions: numeric functions and operators never fail

This is a query behavior change: queries that used to fail now return null, and
integer arithmetic that used to produce a bignum or fail now wraps.

## Problem

Ingest rules (`docs/changes/ingest-rules.md`) evaluate the query engine's expressions
on every ingested event, and a statement that raises fails its event. Many functions
and operators raised on ordinary values: `div` and `mod` by zero, `sqrt` of a
negative, `log` of zero, `exp(1000)`, a float sum past 1e308, `round(1e19)`, an
`INTERVAL` or a date past what timestamps can show, `ip_to_integer` of invalid UTF-8,
a port past 65535. Integer arithmetic grew Erlang bignums that no column can hold, and
the column NIF's `+ - *` on two 64-bit integers was signed overflow, undefined in C.
The two evaluation paths (per event and over a column) could disagree.

The maintainer's decisions: anything that crashes returns null, never NaN or infinity, in
queries as well as rules; integer overflow wraps to signed 64-bit and must match C,
keeping the C path fast; keep it simple.

## Behavior after the change

1. Integers wrap. `+ - *`, unary `-`, `abs`, `div` and integer `sum` wrap to signed
   64-bit, two's complement (`Query.Numeric.wrap/1`). `div(-2^63, -1)` is -2^63. The
   NIF's int64 `+ - *` use `__builtin_add/sub/mul_overflow`, keeping the wrapped
   result: defined behavior, no branches, and the same answer as the Elixir path.
2. A float result that isn't finite is null. Erlang raises on float overflow, so
   float arithmetic catches it; the NIF already stored non-finite results as null.
3. A result with no good value is null: `sqrt` of a negative, `log`, `log2` and
   `log10` of zero or less, `exp` and `power` overflow, `div` and `mod` by zero,
   `round`, `ceil` and `floor` of a float outside int64 (checked after rounding),
   `factorial` above 20 (it used to fail the query), an interval number of more than
   19 digits or a term or total outside int64, date arithmetic outside years 0000 to
   9999, `ip_to_integer` of invalid UTF-8, `url_port` outside 0 to 65535, and
   `format_timestamp` of a month or hour with no name to format (month 13 as `MMMM`;
   a field it only prints as digits is printed as stored).
4. A list storage can't hold (a list holding a list of lists) is null. The check runs
   on every result as it becomes a column or constant, so it covers a list built from
   a field that already holds a list of lists. Engine still validates what a rule
   produces before storing it.
5. Aggregates: integer `sum` wraps like `+`. A float overflow while merging `sum`,
   `avg` or the variance and standard deviation aggregates makes the state an overflow
   marker that absorbs every later merge, across segments and machines, and finishes
   as null. `avg` keeps its exact integer sum and is null if the final division
   overflows.
6. `Query.Limits.check_factorial!/1` is gone.

String functions (`concat` and `||` on lists, `lpad` and `rpad` past the string limit,
regular expressions past their backtracking limit) still fail the query; the string
forms and a global string cap are a separate change.

## Product spec impact

`docs/product/spec.md` section 7: item 3 gains the integer and null rules; item 4
gains the aggregate overflow sentence; item 8 drops "`factorial` takes at most 20".
`lib/web/mcp/query_language.md` says the same. `overview.md`: none. Architecture docs
drop the factorial limit too (`docs/architecture/security.md`, `system.md` 5.7).

## Validation

- `test/query/totality_test.exs`: every registered function and every operator over
  every pair of 24 edge values (0, 0.0, -1, -0.5, ±int64 limits and the floats at
  ±2^63, ±1e308, 1e-308, timestamps at the year 9999 limit, with an offset and with
  out-of-range fields, interval strings at and past int64, an oversized port, invalid
  UTF-8, a mixed list, a list of lists, true, null), three ways: per event, a column
  against a constant, and over multi-row columns (the NIFs). Nothing raises, every
  result is storable, and the three agree, except the string functions named above,
  timestamp string `+`/`-` an integer over columns (TODO.md,
  timestamp-arithmetic-columns), and `replace` against a constant (its pattern is read
  only from a literal).
- `test/query/numeric_test.exs`: wrapping on both paths, non-finite floats, domain
  errors, rounding at 2^63, the interval cases, the date range, ip and port inputs,
  list depth, comparisons at the boundaries, and a GROUP BY `sum` past the float
  range through a query.
- Aggregate tests: `sum` wraps and stays null after an overflow however later rows
  merge; `avg` and `var_pop` likewise. `test/aggregation/overflow_test.exs` merges an
  overflowed `sum`, `avg` and each variance and deviation state with overflowed,
  empty, non-number and ordinary states in both orders.
- `test/rules/ingest_test.exs`: a rule's `div(a, 0)` and `sqrt` of a negative store
  null and its overflowing `a * 2` wraps, instead of failing the event.
- Tests that relied on `div(v, 0)` raising to exercise query failure handling now use
  `test_raise/1`, a function registered only in the test build.
- The full `mix test` suite passes.
