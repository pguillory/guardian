# Share compiled rule execution metadata

Status: implemented and validated.

Product spec impact: none. No statements change in overview.md or spec.md.
Counter identities, hashes, bucket keys, execution order, results and activation
retention remain unchanged.

Compiler previously embedded typed steps three times: in the recovered plan's flat
steps, in that plan's execution levels, and separately in apply/2's levels.
Resolved Plan values keep both representations, because flat metadata order can
differ from the flattened execution order. (Later superseded: Plan now holds only
the flat steps, see `docs/changes/plan-canonical-steps.md`.)

The generated module embeds execution levels once in a private literal
accessor. apply/2 passes those prepared levels straight to Runtime.run/3. There
is no per-event dependency graph construction, flattening or reordering.

At compilation, Compiler records each flat step's integer position in flattened
execution levels and embeds those positions plus the plan's remaining metadata.
Generated plan/0 reconstructs the flat steps from the shared levels on each
activation/reload, including after Server restart. It returns the exact original
resolved Plan, including both orders, canonical source, AST constants, bound
counter definitions and hash.
Server continues to recover prior plans from published modules; no metadata
registry or new lifetime is introduced.

Regression coverage checks exact recovery when the two orders differ, empty
plans and scalar execution through both generated entry points. Existing
all-aggregate round trips, identity/hash baselines, counter execution and
reload/restart tests also passed: 104 focused tests, zero failures, with warnings
as errors. The first focused attempt passed its assertions but failed on warnings
from statically calling not-yet-generated test modules; dynamic calls fixed the
test compilation warnings before the successful focused run.

A before/after inspection of generated BEAM literal tables confirmed three step
copies became one for scalar and counter examples, with exact plan recovery in
each. For a representative 64-SET plan, escaped step copies fell from 192 to 64 and
the serialized literal entries from 69,200 to 23,376 bytes. These are literal-table
measurements, not a claim about total VM memory or event throughput.

Independent Claude and Codex plan and code reviews approved; both code reviewers
completed all five concern helpers. Nonblocking review fixes clarified naming
and documentation and added computed LOOKUP prerequisites to the divergent-order
recovery regression. The affected compiler and plan files passed again: 32 tests,
zero failures. A later refactor to choose a canonical Plan step representation
is separate from this compiled-module payload reduction.

The sole full pre-commit passed formatting, warnings-as-errors compilation and
the default suite: 1,221 tests, zero failures, three excluded large tests.
No deployment or production verification is included.
