# Shared query and counter aggregates

Status: implemented and validated.

Superseded in part by [aggregates-unify.md](aggregates-unify.md), which removes the
opt-in list and the query/counter policy differences tabled below, and by
[counter-merge-order.md](counter-merge-order.md): min/max ties are undefined.

Product spec impact: none. No statements change in overview.md or spec.md.
Query and TRACK/LOOKUP behavior, operators, defaults, numerical policies and
state representations are preserved. This completes the sharing deferred by
[ingest-rules.md](ingest-rules.md), on top of the direct ETS counter store in
[counter-store.md](counter-store.md).

## Design and reconciliation

`Guardian.Aggregation` explicitly opts the existing v1 counter name/arity pairs
into shared per-aggregate implementations. Its query registration alone does not
make an aggregate suitable for counters. The fixed allowlist derives from these
counter configurations. All operator logic lives under `Guardian.Aggregation.*`.
The initial counter API adapter was later retired by carrying resolved shared
configurations through rule plans; see [counter-retirement.md](counter-retirement.md).

The shared registry distinguishes a final empty query result (`default`) from an
empty mergeable counter state (`empty`). Counters run the usual start, merge and
finish operations with explicit options for real policy differences:

| Aggregate | Query policy | Counter policy |
| --- | --- | --- |
| count | Raw integer finish | Int64-or-null finish, including native increments |
| count_distinct | HyperLogLog p14, Array | HyperLogLog p8, 256-byte Bitstring registers |
| sum | Empty query result 0.0 | Empty state/result nil |
| avg | Arithmetic merge of empty states | Empty states skipped without arithmetic |
| min/max | Existing null-skipping, term ordering, right-biased ties | Same |

Query distinct was already approximate, not exact. Changing either precision or
backend would be a behavior/state compatibility change; neither changes here.
Both count arities use explicit query/counter contexts to avoid confusing the
context argument for a query value. Average keeps the existing signed-zero
difference between contexts. It shares numeric merging/finishing; only counter
empty identities differ, and absorbing overflow precedes those shortcuts.
Sum/average skip non-numbers, count(expr)/distinct skip null, and count() counts
every event. Sum's integer wrap and absorbing float overflow remain, as do average's
exact integer sums and weighted bucket merging. Floating-point regrouping and
overflow still limit numerical associativity.

States retain their original shapes: ordinary numbers, nil, :overflow, average
tuples, selected min/max input values and Hypex tuples. ETS and erpc can copy these
terms without mutable resources, owner-local handles or a new serialization layer.
Existing bucket identities, strict unchanged-write comparison, Store CAS rows and
native increments need no migration. Run the same build across a cluster as before.

Counter sizing is unchanged. HLL has fixed registers, and min/max retain one
input whose bytes depend on the input. Count and average hold a fixed number of
integers, but exact bignum byte sizes grow logarithmically with count/sum; these
are not absolute constant-byte states. Store's individual payload checks and
asynchronous resident memory target remain the capacity mechanism, including the
existing native-increment preflight limitation described in counter-store.md.
Query-only top-N and other aggregates do not gain counter support in this change.

## Validation

Independent Claude and Codex plan reviews approved preservation of these policies.
Claude identified a count context/arity collision; the registry consistently uses
explicit contexts for Count. Tests cover registry opt-in/arity validation, unchanged
query defaults/precision/count finishing, bit-level signed-zero behavior, and
continued merging after ETF, local ETS and real local-peer ETS/erpc roundtrips.
Existing query/counter numeric, ordering, HLL and rule integration tests remain.
An original-source comparison also matched all seven counter operators' states
and results bit-for-bit through more than 2,000 pairwise merges, including mixed
values, signed zero, int64 edges and float overflow.

Independent Claude and Codex code reviewers approved after all five concern
helpers completed for each provider. Nonblocking cleanups removed unused callback
wrappers and a tautological assertion, clarified numeric regrouping documentation,
used the count/1 configuration in its test and explicitly checked unchanged states
after transport. Claude's separate follow-up to retire the now-thin counter adapter
by carrying resolved aggregation configurations through rule plans was completed
in [counter-retirement.md](counter-retirement.md). Codex found no separate refactor need.
Final checkpoint: the sole full pre-commit run passed formatting,
warnings-as-errors compilation and the default suite: 1,183 tests, zero failures,
three excluded large tests. Focused checks passed before review and after the
nonblocking cleanups. No full run was repeated.
No deployment or production verification is part of this change.
