# Failure diagnostics

Product spec impact: none. The existing independent, ordered event outcomes in
spec section 5 remain the contract; the reporting fix restores that behavior.
No statements change in overview.md or spec.md.

## Engine fun-frame reporting fix

Engine's ingestion failure reporter stripped arguments only from MFA four-tuples.
A valid BEAM fun stack frame raised inside the reporter, preventing the batch
from returning the failed event's outcome and continuing. Unsupported frames now
become a fixed redacted MFA frame. Existing normal frames keep their locations
and arities; no exception message or event data is added to logs.

The regression injects a fun frame holding a private marker through a test-only
String.Chars implementation. It checks the original failure kind, the redacted
frame, absence of the marker, the unchanged not-stored error and successful
storage of the next event only. The test reproduced the reporter's
FunctionClauseError before the fix.

## Shared diagnostic helpers

The separate refactor moves classification and stack redaction into the leaf
`Guardian.Failure` module. It calls no Guardian subsystem. Rules and Web diagnostic
callers use it directly; `Guardian.Engine.failure_kind/3` and the Storage/Segment
`exit_kind/1` entry points retain compatibility delegates. (A later change,
`docs/changes/ingest-outcome-mapping.md`, removed those delegates; callers use
`Guardian.Failure` directly.)

The helper keeps three existing classification policies distinct: caught failures
normalize errors to exception modules, Storage exits unwrap GenServer calls, and
Rules.Server's raw callback reasons keep its existing atom/tuple-head labels.
Each caller still owns its message, logging frequency and catch/reraise behavior.
Caller-facing query messages in `Guardian.Query.Failure` remain separate.

Engine, Rules.Server and Counters.Store now share the Server's conservative stack
policy: MFA frames retain only arity and typed file/line metadata; unsupported
frames become a fixed `{Guardian.Failure, :redacted, 0, []}` frame. Server's
placeholder module changes from Rules.Server to Guardian.Failure too; this is
diagnostic metadata only. This removes duplicated privacy
policy and contracts unusual-frame diagnostics: Store no longer preserves a fun
frame's arity/location, and Engine/Store no longer keep untyped location values.
HTTP responses, rule outcomes, counter defaults, deadlines and storage formats
do not change.

Focused helper tests pin the existing labels, compatibility delegates and stack
policy, alongside integration regressions for ordered ingestion, actual Rules and
Store crashes, JSON failure handling and query recorders. Independent Claude and
Codex plan and code reviews approved the two-commit change. Focused validation
with warnings as errors passed: 168 tests, zero failures.

The sole full pre-commit passed formatting and warnings-as-errors compilation;
the suite ran 1,214 tests with one failure and three excluded large tests. Its
namespace invariant allowed only two named external protocol implementations,
rejecting the new String.Chars fixture despite the documented naming rule.
The test now recognizes external implementations from their protocol metadata,
requiring a Guardian-owned target and the canonical protocol/target module name.
This integration correction accompanies the fixture in the reporting-fix commit.
After that correction, formatting and warnings-as-errors compilation passed;
namespace and all affected files passed with 169 tests, zero failures. A second
full run was omitted.
