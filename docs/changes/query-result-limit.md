# query-result-limit: at most 10,000 rows, LIMIT or not

## Problem

A query could return at most 100,000 rows and about 64 MiB. A bigger result failed
mid-query with "query result exceeds ...; add a LIMIT", so any query without `LIMIT`
over a big table was an error. The two caps were application env settings
(`query_max_result_rows`, `query_max_result_bytes`), and the only tests that lowered
them made `limits_test` synchronous.

## Change

Preston's decision:

1. A `LIMIT` over 10,000 is a parse error: "LIMIT 10001 exceeds the maximum of 10000",
   pointing at the `LIMIT`, so it's reported and recorded like any other parse error.
2. A query without `LIMIT` runs as if it had `LIMIT 10000`, silently. The
   "add a LIMIT" error is gone. The planner adds it to the top-level statement only,
   so HAVING's inner statements aren't limited, and aggregates still read every row.
   A GROUP BY with more than 10,000 groups returns 10,000 of them. Without ORDER BY,
   which rows depends on arrival order.
3. The 64 MiB result cap, both settings, the mid-query row count and the run-time
   ORDER BY ... LIMIT check are gone.
4. Because every top-level plan now has a limit, ORDER BY without LIMIT runs the
   distributed top-n path (`{:order_by_limit, ...}`), and the in-memory
   `{:order_by, ...}` step is gone. A result of up to 10,000 rows is the same as before
   apart from the order of ties for an input that isn't a FROM scan or a GROUP BY,
   which now depends on arrival; a bigger one is its first 10,000 rows. Each machine keeps its top
   10,000 rows, and the coordinator merges them as they arrive (it no longer collects
   every machine's rows into one list first), holding about 10,000 rows plus a chunk.
   For an input that isn't a FROM scan or a GROUP BY (no FROM, `schema`, HAVING's
   second half), that is one more fan-out than before.
5. A pipeline stops reading once the limit is reached, as it already did with an
   explicit `LIMIT`. So a failure past the 10,000th row (an expression error, a
   crashed worker, a lost machine) can now return 10,000 rows instead of an error.
   The spec's "fails the whole query" statements carry this exception. `SHOW TABLES`
   and `DESC` are queries too, so a table with more than 10,000 columns lists 10,000.

`limits_test` is async. It keeps its string-function tests and gains one over 10,001
rows: no `LIMIT` gives 10,000 rows, `count()` sees all of them, and ORDER BY without
LIMIT gives the top 10,000 in order.

## A result of large values

The heap limit doesn't stop a large result. Shared binaries, which is what long
strings are, are left out of it. In a local test VM at production's 256 MiB limit,
results went through the real MCP HTTP endpoint while a second session ran
`SELECT 1` every half second. The table held 12,000 rows of 20 KB strings, so the
query returned 10,000 of them, selecting the column 1, 2, 4 or 8 times:

| Response | Time | Peak VM memory | Peak RSS |
| --- | --- | --- | --- |
| 191 MiB | 0.6 s | 0.5 GB | 1.0 GB |
| 382 MiB | 1.3 s | 1.5 GB | 1.7 GB |
| 764 MiB | 2.9 s | 3.0 GB | 2.4 GB |
| 1.5 GB | 6.0 s | 6.1 GB | 3.5 GB |

The VM held about 0.3 GB of table data before the runs. With 2 KB strings, 10,000
rows give 19 to 77 MiB responses and peaks of 0.2 to 0.4 GB. Every query succeeded,
nothing was logged, and the other session and the node answered throughout. The
memory lingers: after the 1.5 GB run, the VM still had 6 GB of binaries 5 s later,
because idle processes held references to them until their next garbage collection.
Forcing a GC of every process brought that down to 4 GB. A machine with 1 GB would
run out of memory on the 382 MiB case. Preston accepted this as a known limitation
(spec section 12).

A result of many small values does hit the heap limit. With 100,000 rows (before the
limit was lowered), 80 or more integer columns failed in under a second with "a query
process was killed; it may have exceeded its 256 MiB heap limit; ...". The failure
isn't logged (`error_logger: false`), memory came back, and other sessions were
unaffected. 40 columns succeeded with a 52 MiB response, which peaked near 2 GB of VM
memory: the result is copied into the MCP handler, turned into maps and encoded, all
outside the heap limit. That peak predates this change; the old caps let it through
too.

## Product spec impact

Section 7, item 8 (Results): the 100,000-row and 64 MiB caps and "never a truncated
answer" are replaced by the 10,000-row `LIMIT` maximum and the implicit `LIMIT
10000`. Section 12 gains item 4 (no byte cap on results; rows of very large values),
and the later known gaps are renumbered. The overview's reading item says results are
cut to 10,000 rows rather than failing.

## Validation

Parser, planner and `limits_test` tests. The large-result measurements above came
from a throwaway local test, not committed.

## Deploy notes

No config or data change. Callers see:

1. A query that failed with "query result exceeds 100000 rows" or "... MiB" now
   returns 10,000 rows.
2. A query without LIMIT that returned 10,001 to 100,000 rows now returns 10,000,
   with no error.
3. A query with `LIMIT` over 10,000 now fails at parse.
