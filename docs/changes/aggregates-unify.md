# One aggregate behaviour for queries and counters

Status: implemented and validated.

## Problem

Counters used a separate opt-in list of seven aggregate configurations, with
policies that differed from queries: int64-bounded count finishing, a precision-8
distinct sketch against the query's precision 14, a null empty sum against the
query's 0.0, and empty-state shortcuts in average that queries lacked. Arbitrary and
the top-N family had no empty mergeable state, so they could not be counters.

## Behavior after the change

Every registered aggregate and arity is a TRACK operator, with exactly the
configuration a query uses. There are no query/counter options.

1. Every aggregate module defines `empty`, an exact identity of its merge. The
   registry's `default/1`, a query's result for no rows, is the finished empty
   state, so a missing or failed counter gives the same result as an empty query:
   0 for count, count_if and count_distinct, true for all, null otherwise.
   Arbitrary and the top-N family use the non-storable atom `:empty`, so arbitrary
   keeps a real null as a value. Top-N states with different n still raise when
   merged: a query reports the error; a counter fails open to null, through
   Machine's bucket error (current-bucket CAS merge, not logged) or Runtime's
   counter guard (cross-bucket combine, logged by location and kind).
2. The counter opt-in list, `fetch_counter!/1` and `counter_operators/0` are gone.
   TRACK validation checks `Guardian.Aggregation.names_and_arities/0`, the registry
   the parser already uses, so in practice an unknown name or arity is a parse
   error.
3. count_distinct is Hypex precision 8 with 256-byte bitstring registers
   everywhere. Query estimates now have about 6.5% standard error instead of about
   0.8%; small cardinalities stay close to exact through linear counting.
4. `sum` over no rows is null in queries, as in standard SQL. Groups with rows but
   no numbers were already null.
5. Count finishes raw. The int64 limit applies where values are stored: Engine's
   validation of rule outputs drops a TRACK/LOOKUP count beyond int64 (other
   fields are stored), where the counter previously wrote null; query column
   construction validates query results. Later statements in the same rule run
   can read the raw count before the stored-row check. Reaching this needs more
   than 2^63 increments.
6. Average skips states with no values in queries too, so `avg` over `[-0.0, null]`
   is -0.0 where it was 0.0.
7. No new caps: n and state size are bounded only by Store's payload refusal and
   memory target. Arbitrary, `_by` and `_n` states retain input values, like
   min/max, and can hold sensitive values after UNSET.

Counter identities and plan hashes are unchanged: neither includes the resolved
configuration. Counter sketches were already precision 8. During a rolling deploy,
a distributed count_distinct query can fail while old nodes return precision-14
sketches (cross-version queries are already unsupported); a deploy resets counters.

## Product spec impact

`docs/product/spec.md`: counter operators are every query aggregate with query
semantics and no-rows missing results ([Counters item 1 and the UNSET memory note
in item 7](../product/spec.md#514-counters)); count_distinct's precision 8 in the
aggregate list; `sum(x)` is null for an empty table. MCP `query_language.md` and the
write_rule tool description match.
`docs/product/overview.md`: none. `docs/architecture/security.md` names the newly
value-retaining counter states.

## Validation

Independent Claude and Codex plan reviews approved. Their non-blocking notes added
the per-aggregate no-rows table, the stored-row int64 ingest test, signed-zero bit
assertions and the notes above. New tests cover every registered aggregate's
no-rows result and two-sided empty identity, arbitrary's real null, top-N empty
merges and mismatched n (both counter paths, with a sibling counter unaffected),
every aggregate as a TRACK operator through real buckets, query p8 sketches, the
null empty sum and signed-zero average in queries.

Independent Claude and Codex code reviews ran five per-concern helpers each. Codex
approved; Claude's one blocking finding (the rules guide still listing seven
operators and the 0.0 sum) and the non-blocking documentation, test and
simplification notes were fixed without another round. Focused aggregation, rules,
counters, MCP and query suites passed before review. The sole full pre-commit run,
after merging main, passed formatting and warnings-as-errors compilation and ran
1,255 tests with one failure (three large tests excluded): a 50 ms owner-call
timeout in an unchanged peer test in client_test.exs, under heavy machine load.
The base commit showed the same peer flake, which is queued as its own fix. At low
load, client_test.exs (24 tests) and counter_ingest_test.exs (9 tests) then passed,
and the commit was made with the hook skipped. No deployment or production
verification was performed.
