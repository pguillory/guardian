# query-heap-fixed: a fixed per-process query heap limit

## Problem

`GUARDIAN_QUERY_MAX_HEAP_MB` set the heap limit of each process a query runs in
(default 256 MiB), with `0` turning it off. Only the maintainer's deployment set it,
to `0`, to keep behaving as it did before the limit existed. The off mode needed its
own fallbacks (the large-value `replace` helper and the rule worker each had a
separate path) and left that deployment with no per-process bound at all.

## Change

1. Every query process, `Guardian.Query.DistributedStream` worker, large-value
   `replace` helper and rule worker has a 256 MiB heap limit, always. There is no
   off mode.
2. `GUARDIAN_QUERY_MAX_HEAP_MB` no longer exists. If still set it is ignored, like
   any unknown variable.
3. The heap-kill message names the size: "a query process was killed; it may have
   exceeded its 256 MiB heap limit; narrow the query with WHERE, LIMIT or fewer
   groups".
4. The `:query_max_heap_mb` application environment value stays, only so tests can
   lower the limit to provoke kills quickly. It is not an operator setting.

Why a fixed value rather than keeping the setting: no one but the maintainer's
deployment set it, and only to turn it off. In that deployment `system_stats`
showed the memory of all Erlang processes together staying far under 256 MiB. That
is margin at sampled instants (one-second samples can miss a shorter spike), not a
proven bound. A later need for a different value can bring a setting back.

## Product spec impact

Section 5.7: the heap limit is a fixed 256 MiB, with no setting, and the error
message names the size instead of the variable; the `replace` helper no longer has
an off-mode fallback. The `replace` match bound in the functions section is stated
at the 256 MiB limit instead of "the default heap limit ... fewer with a lower
limit".

## Validation

`test/guardian/query/heap_limit_test.exs` checks the 256 MiB default, kills over a
lowered limit, and a peer node applying its own value.
`test/guardian/query/regex_memory_test.exs` runs millions of empty matches under the
default limit. `test/guardian/rules/ingest_test.exs` still checks a rule worker's
heap kill without the error_logger report. `test/guardian/config/runtime_test.exs`
checks that the old variable is ignored.

## Deploy notes

A deployment that set `GUARDIAN_QUERY_MAX_HEAP_MB=0` now has the limit. A query or a
batch of events under rules whose process grows past 256 MiB now fails: a query with
the message above, an event with "rules for <table> exceeded their time or memory
limit; the event was not stored".
