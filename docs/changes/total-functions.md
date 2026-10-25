# total-functions: functions and operators never fail

This is a query behavior change: queries that used to fail now return null or a cut
string, integer arithmetic that used to produce a bignum or fail now wraps, and
`to_string`, `concat` and `||` render every value. It landed in two commits: numbers
(items 1 to 6), then strings (items 7 to 11).

## Problem

Ingest rules (`docs/changes/ingest-rules.md`) evaluate the query engine's expressions
on every ingested event, and a statement that raises fails its event. Many functions
and operators raised on ordinary values: `div` and `mod` by zero, `sqrt` of a
negative, `log` of zero, `exp(1000)`, a float sum past 1e308, `round(1e19)`, an
`INTERVAL` or a date past what timestamps can show, `ip_to_integer` of invalid UTF-8,
a port past 65535. Integer arithmetic grew Erlang bignums that no column can hold, and
the column NIF's `+ - *` on two 64-bit integers was signed overflow, undefined in C.
The two evaluation paths (per event and over a column) could disagree.

Strings had the same problem: `concat` and `||` raised on some lists and gave
meaningless text for others (`[1, 2]` became the bytes 1 and 2), `lpad`, `rpad`,
`concat` and `replace` failed the query past a 16 MiB limit, and a regular expression
past its backtracking limit, a `\C` match splitting a character, or a `replace` with
too many matches failed it too. `to_string` gave null for anything but a string.

The maintainer's decisions: anything that crashes returns null, never NaN or infinity,
in queries as well as rules; integer overflow wraps to signed 64-bit and must match C,
keeping the C path fast; `concat` and `to_string` handle lists with a defined string
form; one global string cap of 64 KiB, cutting UTF-8 safely; a regular expression
past its limit gives null; keep it simple.

## Behavior after the change

1. Integers wrap. `+ - *`, unary `-`, `abs`, `div` and integer `sum` wrap to signed
   64-bit, two's complement (`Guardian.Query.Numeric.wrap/1`). `div(-2^63, -1)` is -2^63. The
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
6. `Guardian.Query.Limits.check_factorial!/1` is gone.

7. String forms (`Guardian.Query.Text.form/2`): a string as it is; an integer in decimal; a
   float in its shortest round-trip form (`1.0e300`); `true`, `false`; a list as
   compact JSON-style text, `[1,null,"a",[2.5]]`, its strings quoted and escaped as
   JSON with invalid UTF-8 bytes as U+FFFD. `to_string(x)` gives the form, and null
   for null; `concat` and `||` use it with null as the empty string. Rendering stops
   at its budget, so a huge list costs no more than the cap. Over a column of only
   strings and nulls, `to_string` still returns the column at once (the NIF).
8. One string cap, 64 KiB (`Guardian.Query.Text.max_bytes/0`, fixed; the
   `:query_max_string_bytes` setting and its 16 MiB default are gone). `concat`, `||`,
   `lpad`, `rpad`, `replace`, `to_string`, `lower`, `upper`, `normalize` and
   `format_timestamp` cut their results to it at a UTF-8 character boundary (bytes,
   for invalid UTF-8), copying a cut result so it never keeps a larger original
   alive. `lpad` and `rpad` build no more padding than fits, `concat` renders no more
   than fits, and `replace` stops splicing at the cap, so none builds a large string
   first. Functions that return an input or part of one (`to_string` of a string,
   `substr`, the trims, `if`, `coalesce`, URL and email parts) are not cut.
9. `ILIKE` and `NOT ILIKE` no longer rewrite to `lower(x) LIKE lower(p)`: they
   lowercase both sides internally, without the cap, so a long value matches `ILIKE`
   exactly as its lowercase matches `LIKE`. A constant pattern is lowercased and
   compiled once.
10. Regular expressions: past the backtracking limit, `RLIKE`, `NOT RLIKE` and
   `replace` are null for that value (so WHERE drops the row either way); so is a
   `replace` whose match splits a character or whose value has too many matches to
   hold (its helper process killed by its heap cap). The engine and its limits are
   unchanged.
11. UTF-8 truncation (`Guardian.Query.Text.truncate/2`) moved from `Guardian.Web.QueryParseErrors`,
   which, with `Guardian.Web.QueryLog`, now uses it from there.

With every function total, a rule statement fails only through a bug; the test build
registers `test_raise/1` for the tests that need one.

## Product spec impact

`docs/product/spec.md` section 7: item 3 gains the integer and null rules; item 4
gains the aggregate overflow sentence; item 8 drops "`factorial` takes at most 20".
`lib/web/mcp/query_language.md` says the same. `overview.md`: none. Architecture docs
drop the factorial limit too (`docs/architecture/security.md`, `system.md` 5.7).

Strings: spec section 5.1 item 5 (a rule statement no longer fails on a regular
expression limit); section 7 item 5 (string forms, the cap and the functions it
applies to, `ILIKE` on long values, null from `RLIKE`, `NOT RLIKE` and `replace` at
their limits) and item 8 (the 16 MiB refusal goes). The MCP reference, security.md
5.2, system.md 5.6, 5.7 and the settings table (the `query_max_string_bytes` row),
and `docs/reference/limitations.md` follow.

## Validation

- `test/query/totality_test.exs`: every registered function and every operator over
  every pair of 24 edge values (0, 0.0, -1, -0.5, ±int64 limits and the floats at
  ±2^63, ±1e308, 1e-308, timestamps at the year 9999 limit, with an offset and with
  out-of-range fields, interval strings at and past int64, an oversized port, invalid
  UTF-8, a mixed list, a list of lists, true, null), three ways: per event, a column
  against a constant, and over multi-row columns (the NIFs). Nothing raises, every
  result is storable, and the three agree, except `replace` against a constant (its
  pattern is read only from a literal). Timestamp string `+`/`-` an integer over
  columns was a second exception until it was fixed (TODO.md,
  timestamp-arithmetic-columns).
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
- `test/query/text_test.exs`: truncation at character boundaries and its copy; string
  forms of every kind of value and their budget on a huge nested list; `concat`, `||`,
  `lpad` and `rpad` at and past the cap; `lower`, `upper` and `normalize` where
  expansion passes the cap (ŉ, İ, NFD é); `format_timestamp` with a long format;
  `concat` and `||` stopping at their first cut piece; `replace` cutting a long
  replacement or slice before appending it.
- `test/ast/node/operators/ilike_operator_test.exs`: `ILIKE` and `NOT ILIKE` on a
  value whose match lies past 64 KiB, and agreement with `LIKE` on lowercased text,
  invalid UTF-8 included.
- String tests: `to_string` forms, escapes and invalid UTF-8 in a list, the cap, and
  the column fast path; `replace` cut at the cap and null for `\C` and the
  backtracking limit, small and large values alike; `RLIKE` and `NOT RLIKE` null at
  the limit; many-match `replace` null through the helper (`regex_memory_test.exs`);
  a rule's `RLIKE` and `replace` at the limit store null.
- The totality grid gains a value past the cap; every built string is within it, and
  the string functions are no longer exempt.
- Tests that relied on `div(v, 0)` raising to exercise query failure handling now use
  `test_raise/1`, a function registered only in the test build.
- The full `mix test` suite passes.
