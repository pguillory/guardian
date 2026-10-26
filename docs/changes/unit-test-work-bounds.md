# Unit-test work bounds

The shared helpers named below now live under `Guardian.Test.*`; see
[test support namespace](test-support-namespace.md) for the mapping.

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

- QueryLog and QueryParseErrors: two 1 s guards while the recorder is suspended.
  These distinguish an asynchronous handoff from a blocking recorder call.
- Deployment: a 4 s shutdown guard distinguishes interrupting a 5 s restart pause
  from waiting it out. This tests actual time-dependent process behavior.
- Segment reader: 4.9–8 s checks the real 5 s storage timeout. A separate measured
  query duration chooses deadlines for a race test; it asserts no fixed CPU limit.
- ObjectStore: returned object age must be nonnegative and below 5 s. This checks
  timestamp freshness and can fail after a sufficiently delayed put/list/get.
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

## Follow-up: LIKE, integer tokenization and timestamp freshness

The six remaining LIKE CPU guards and the million-digit integer tokenizer guard
now measure caller reductions through the test-only `Guardian.WorkBounds` helper.
String rendering and RowIndex use that helper too, preserving their workloads and
bounds. Inputs are built before measurement; the result assertions remain.
Product spec impact remains none.

LIKE retains the existing SQL evaluation helper coverage, and the oversized
65,536-code-point pattern still calls the operator directly. The valid
1,000-code-point pattern keeps its literal-case result assertion; its work bound
moves to a 1,000-row column snapshot, built outside the measurement. This
distinguishes compiling a constant pattern once from compiling it again for each
row; literal operands alone did not exercise that distinction.

Calibration on Elixir 1.19.3 / OTP 28.5.0.8 gave the following reduction counts.
LIKE bounds allow at least three times the baseline work; every LIKE
regression exceeds its bound by at least four times. The tokenizer has less
separation: its bound allows 50% above the million-reduction scan, while a native
conversion before the range check costs about 2.37 million reductions overall.
This includes the scanner and the same parse-error path, rather than inferring
coverage from the conversion alone. Native integer conversion is charged enough
on this runtime to distinguish that regression without call tracing or heap limits.

| Workload | Baseline reductions (approximate) | Bound | Representative regression |
| --- | ---: | ---: | ---: |
| 1,000-character value, 20 `%_` pairs then `x` | 40,000 | 200,000 | naive backtracker stopped above 2,000,000 |
| 30-character value, 31 `%_` pairs | 4,000 | 25,000 | naive backtracker stopped above 2,000,000 |
| 16,384-character value, 999 `%a` pairs then `%b` | 1,375,000 | 5,000,000 | historical backtracker stopped above 20,000,000 |
| 80-character value, `%a%a%a%a%a%b` | 4,800 | 25,000 | historical backtracker stopped above 20,000,000 |
| 65,536 distinct code points, direct operator call | 138,000 | 500,000 | uncapped compiler stopped above 2,000,000 |
| 1,000 distinct code points, constant pattern over 1,000 column values | 54,000 | 500,000 | per-row compilation: 10,145,000 |
| Million-digit out-of-range integer | 1,000,034 | 1,500,000 | convert before checking range: 2,374,000 |

Negative controls ran only in throwaway VMs from scratch scripts, with no production
source edits. The `%_` control uses ordinary recursive wildcard backtracking without
the historical `%_` normalization; that normalization already handles these two
inputs cheaply. Alternating literals use the historical recursive matcher. The
compiler control lifts the item cap, and the constant-pattern control restores
per-row compilation through the real query path. Runaway controls were isolated
in monitored processes and stopped after exceeding reduction budgets; their
reported counts are lower bounds, not completed workloads. The tokenizer control
retains the scanner, range rejection and parse-error construction, but converts the
integer before comparing it with int64's maximum. Two runs measured about
2,374,000 reductions, versus 1,000,034 for the current tokenizer. Direct native
conversion alone charged about 1.37 million reductions.

SystemStats now checks its second-precision UTC timestamp between timestamps
captured before and after collecting metrics, inclusively. Scheduler pauses no
longer invalidate a fresh timestamp. This still assumes the wall clock does not
step backwards during the call. ObjectStore's age assertion and actual timeout,
lease, cooldown and asynchronous-handoff checks remain unchanged.

The five affected test files passed together with seed 357856 (37 tests).
Independent Claude and Codex plan and code reviews approved this follow-up.
