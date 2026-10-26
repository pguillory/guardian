# Unit-test work bounds

Status: implemented.

Product spec impact: none. No statements change in overview.md or spec.md.
Production behavior and performance are unchanged.

## Problem and change

The nested-list string-form test required rendering to finish within 100 ms. It
failed under host load even though it returned the correct 100-byte prefix. The
guard is meant to reject rendering the whole million-string list before cutting,
rather than enforce a latency promise. It now measures reductions in the calling
process around `Text.form/2`, with a generous bound of 100,000 reductions.

The three RowIndex cost checks likewise had 500 ms limits. They now measure
caller reductions with a bound of 2,000,000 per workload. As before, the first
statement builds the index outside the measured interval, and the remaining 999
statements should cost what they touch. The guard rejects repeated whole-row
scans, including scans over removed case variants after UNSET.
All output assertions remain.

Reductions are a runtime-specific proxy for work, not exact CPU accounting. They
do not count time spent waiting for a scheduler; native operations may charge
them approximately. These tests exercise synchronous rendering and rule
evaluation in the caller. Separate calibration runs confirmed that representative
regressions exceed the bounds on the supported runtime.

## Other timing assertions

The suite scan leaves these unchanged:

- LIKE operator tests: six 1 s guards against backtracking and expensive pattern
  compilation. These CPU guards are candidates for a separate work-bound change
  with their own negative controls; they have wider margins than the changed tests.
- Tokenizer: a 1 s guard against converting a million-digit literal to a bignum.
  Also a candidate for a separate work-bound change, accounting for native integer
  conversion rather than assuming reductions capture it.
- QueryLog and QueryParseErrors: two 1 s guards while the recorder is suspended.
  These distinguish an asynchronous handoff from a blocking recorder call.
- Deployment: a 4 s shutdown guard distinguishes interrupting a 5 s restart pause
  from waiting it out. This tests actual time-dependent process behavior.
- Segment reader: 4.9–8 s checks the real 5 s storage timeout. A separate measured
  query duration chooses deadlines for a race test; it asserts no fixed CPU limit.
- SystemStats: a timestamp freshness check within 5 s. It tests timestamp content,
  although a pause before the comparison can still fail it.
- ObjectStore: returned object age must be nonnegative and below 5 s. This checks
  timestamp freshness too, and can fail after a sufficiently delayed put/list/get.
- PersistedSegments scheduling: a 3 s polling deadline allows successive 1 s
  persistence ticks. Other storage/query helper deadlines, Task.await and
  assert_receive limits bound asynchronous waits rather than CPU benchmarks.
- Object-store lock: remaining-lease assertions check actual lease durations,
  including the 30 s upper bound and 25 s lower margin for a freshly acquired lease.
- Rules Server: a 900 ms lower bound checks boot retry pacing. Scheduler delays
  cannot violate this lower bound; it is not a CPU performance limit.

Counter budget, timeout, cooldown, clock and timer checks are outside this change;
their timing semantics are intentional. See counter-test-budgets.md for the
recent budget-test work.

## Validation

Independent Claude and Codex plan and code reviews approved the approach.
Calibration on Elixir 1.19.3
and OTP 28.5.0.8 measured about 724 reductions for the 100-byte string form, versus
159 million when rendering nine million bytes of the same list. The RowIndex
workloads used about 190,000, 156,000 and 66,000 reductions, respectively. One
historical whole-row write scan used 2.7 million, and one case-folded variant read
scan used 3.6 million, already above the whole-workload bound.
Ten reads that scan all 100,000 stale case variants after their removal used
7 million reductions; the indexed test performs 999 reads within its bound.

Both changed test files passed together twice (15 tests per pass) with the
original failure's seed, 357856. Further repetitions were stopped when host load
exceeded the development run limit; an incomplete pass is not counted. The
normal full pre-commit checks run at commit.
