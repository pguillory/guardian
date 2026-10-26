# Check the Rules save margin against the S3 write deadline

Status: complete.

Rules reserves 80 s of its write lock's lease before saving, comfortably longer
than the S3 client's 20 s write deadline and the time before the write starts.
That dependency was documented but not checked in code.

`Guardian.ObjectStore.S3.write_deadline_ms/0` exposes the existing effective
put/delete deadline, including its application-env test override. The write path
uses that same accessor. A Rules policy test clears both test overrides and checks
that the default save margin strictly exceeds the default S3 deadline. The S3
failure test also checks that the accessor honors its shortened deadline.

The margin stays explicit Rules policy rather than deriving it from the client
deadline: changing the deadline must prompt a conscious margin decision. Test
overrides stay tight; the 80 s margin, 20 s deadline and 120 s lease are unchanged.

This completes the deadline-check follow-up in
[`object-store-local.md`](object-store-local.md). No real S3 calls are needed.

Product spec impact: none. Store behavior, lock semantics and runtime timing are
unchanged.

Validation: the focused S3, Rules.Store and Rules.Server tests passed (39 tests).
The changed S3 and Store tests also passed again (8 tests). Formatting and
warnings-as-errors compilation passed in the one full pre-commit run.

That full run had 1 failure among 1,307 tests (3 excluded), seed 919715:
CounterRuntimeTest's "many rules across events stop waiting when the failed-call
batch allowance runs out" expected a failed-call allowance below 10,000 but saw
78,156. The 1-minute host load was 12.92 at completion; start load was not sampled.
A counter-runtime file rerun (30 tests, seed 162683) passed that test but failed
"concurrent generic CAS updates include their event or explicitly default on
conflict": the final lookup was nil instead of 25. Its 1-minute load was 12.92
before and 12.98 afterwards.

Both pre-existing counter-test failures were routed to the separate counter-test
stabilization work. This change touches neither counters nor the Rules runtime.
The maintainer authorized committing with these recorded failures and passing
focused changed tests, without a second full-suite run.
