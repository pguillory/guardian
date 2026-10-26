# CounterDefinition as the single source of TRACK metadata

Status: implemented and validated.

Product spec impact: none. No statements change in overview.md or spec.md.
Counter identities, base and resolved plan hashes, bucket keys, results, defaults,
dependency order, budgets and coherent reload behavior remain unchanged.

Step construction builds a CounterDefinition from the parsed TRACK and its
canonical source. It owns identity, operator, window_ms, bucket_ms and group_arity;
TRACK steps keep expressions and diagnostic locations, with no flat copies of
counter metadata. Invalid intervals remain nil, and Validation checks the
operator and window before plan construction. Construction makes no aggregate
registry lookup, so invalid operators still produce ordinary validation diagnostics.
RuleSet no longer needs a separate counter preparation pass, and LOOKUP resolution
binds the same definitions as before. Generated plan recovery preserves them exactly.

Queries and counters already share every aggregate configuration. Neither TRACK
steps nor CounterDefinition store a derived aggregation anymore: execution selects
the shared aggregation with `Guardian.Aggregation.fetch!(name)` from the operator,
then uses the existing empty/start/merge/finish and key-machine APIs.
This deliberately replaces construction-time configuration resolution with a
constant-map lookup during event execution.

Identity still hashes the identical canonical source with SHA-256. The explicit
struct-shaped hash_term map retains exactly the same keys and values, and
Resolution's deterministic ETF encoding is unchanged. The fixed counter identity,
base-plan and resolved-plan hash constants are retained unchanged. As with other
generated plan representation changes, the existing full-release-restart model
applies; this adds no mixed-version hot-loading support.

Validation covers parsed metadata and invalid windows/operators, removal of flat
fields and aggregation configuration, every registered aggregate, shared
TRACK/LOOKUP definitions, exact generated plan recovery, fixed hashes, counter
execution/defaults and reloads. No deployment or production verification is included.

Independent Claude and Codex plan and code reviews approved; each code reviewer
completed all five concern helpers. Small nonblocking cleanups clarified docs and
comments, made window/bucket calculation private, and used literal test
expectations. The existing fixed identity and plan-hash constants passed unchanged.

Before editing production code, the baseline counter-plan tests passed (30 tests).
The focused rules/counters run executed 234 tests with one failure in the new
test's parser return-pattern assumption. Correcting that assumption and rerunning
the counter-plan file passed all 31 tests; the other focused tests had passed.
After merging the concurrent test-helper changes, the sole full pre-commit passed
formatting, warnings-as-errors compilation and the default suite: 1,311 tests,
zero failures, three excluded large tests.
