# Rules Subsystem

Ingest-time rules: files of SET, UNSET, TRACK and LOOKUP statements, one folder per table
(`<table>/<name>.gsql`), run on each event sent through the ingest APIs before it is
stored. The design and its reviews are in `docs/changes/ingest-rules.md`; user-visible
behavior is [spec section 5.1](../../../docs/product/spec.md#51-rules).
Read both before changing this.

Modules:

- `Guardian.Rules`: the API (`lookup/1`, `run/2`, list/read/write/delete, `reload/0`). Lookups
  read one `:persistent_term` map of table to compiled module, or `{:invalid,
  message}` for a table whose stored rules fail validation.
- `Guardian.Rules.RuleSet`: parses (`Guardian.AST.Parser.parse_rules/1`) and validates a whole set,
  every table together, into one `Guardian.Rules.Plan` per table. Pure: no reads, no state.
  `prepare/1` checks counter semantics and returns unbound candidates plus resolved
  plans; public validation and Server writes/loads use the same preparation.
  Only resolved plans have `resolved?: true`.
- `Guardian.Rules.Step`: typed per-kind inputs and read derivation.
- `Guardian.Rules.Validation`: scalar, counter aggregate, interval and FROM checks.
- `Guardian.Rules.DependencyGraph`: deterministic flat ordering and dependency levels with
  the explicit LOOKUP barrier. Plans hold only the flat steps; Compiler derives the
  levels from them once per compiled module.
- `Guardian.Rules.Resolution`: immutable target definitions and fixed-point invalidity.
  Resolved plan hashes use deterministic ETF, so they match across VM starts.
- `Guardian.Rules.CounterDefinition`: the single owner of counter identity, operator,
  window/bucket sizes and grouping arity. Step builds it for a parsed TRACK;
  Validation checks its operator and window before plan construction, and LOOKUPs
  and Runtime reuse it.
  `hash_term/1` owns the target's struct-shaped hash input. Execution selects the
  shared aggregation with `Guardian.Aggregation.fetch!(name)`.
- `Guardian.Rules.Activation`: pure coherent reload selection, used by Publisher.
- `Guardian.Rules.Publisher`: synchronous activation/publication and generated-module
  pool ownership, called inside Server's scrubbed callbacks. Recovers prior plans
  only from published modules; its state contains only free names and retired
  statuses, never plans, sources or diagnostics. Reclamation timers target Server.
- `Guardian.Rules.Compiler`: a plan into a generated module from a fixed template, with the
  execution levels, derived from the flat steps at compile time, as one shared escaped
  literal. Generated `plan/0` reconstructs the exact resolved plan's flat order from
  compile-time positions for activation, including after restart; reconstruction
  never runs during ingestion. Metadata is bounded and reclaimed with the module pool.
  No rule text becomes code. Unresolved plans and unbound LOOKUPs cannot compile.
- `Guardian.Rules.Runtime`: the dispatcher called by generated modules (reads, SET, UNSET,
  failures), threading a `Guardian.Rules.RowIndex` through dependency levels. Internal
  TRACK/LOOKUP dispatch uses bound identities and aggregate defaults on failure.
  For each level, Runtime prepares every counter statement as skipped, failed or
  an op, runs the ops through `Guardian.Counters.Execution.run_counters/3` (the
  counters layer: buckets, rounds, routing, combination;
  `lib/guardian/counters/CLAUDE.md`), writes each result into its field and logs
  `{:error, kind}` results by file and line (`docs/changes/counter-execution-layer.md`).
- `Guardian.Rules.Event`: private Unix/monotonic arrival coordinates outside the row; Engine
  captures them before validation. Runner adds a typed Counters.Context under
  Event.counters on worker entry, sharing one batch atomics budget across
  replacement workers.
- `Guardian.Rules.RowIndex`: the event's row, with a trie of its keys by lowercase object path
  and a map of lowercase spelling to present keys, so a statement costs what it
  touches rather than a pass over every column. Its tests check it against the old
  scan, reimplemented in the test.
- `Guardian.Rules.Runner`: runs a batch in a worker under the heap limit, 1 s per event.
- `Guardian.Rules.Config`: chooses the store from the environment.
- `Guardian.Rules.Server`: process, startup load, reload, poll, locked writes and
  admission. Owns rule lock policy (key, lease and save margin). The store is a
  `Guardian.ObjectStore` (`lib/guardian/object_store/CLAUDE.md`): S3 or a local folder.
  Both list every object; Server and `Guardian.Rules.list_rules/1` apply the rule
  layout (`Guardian.Rules.RuleSet.parse_key/1`). The write lock is a
  `Guardian.ObjectStore.Lock`; stores declaring `ObjectStore.shared?/1` false refuse
  writes with peers connected. Holds Publisher's pool value and forwards reclamation
  messages.

## Rules to keep

1. Nothing reads the store per event. The ingest path sees only the published map.
2. Never load a module name twice while anything can call it. Compile into a free
   pool name, publish the whole map at once only after every changed table compiled,
   and reclaim retired names only after the grace period and a successful
   `:code.soft_purge/1`. Never `:code.purge/1` a published or retired module.
3. Atoms stay bounded: module names come only from `Guardian.Rules.Compiler`'s pool. Never
   create an atom from rule text, a table name or a store key.
4. Credentials never leave `Guardian.ObjectStore.S3` or `Guardian.Rules.Config` (the
   object store's rule 2). Never log or return a response body, header, request, or
   a caught exception's message from a store call.
5. Rule failures are logged by file, line and kind only, never a value (event values
   can be the very secret an UNSET removes). Validation errors are logged the same
   way, never by message: a message can quote rule text. The rule worker reports
   heap kills without the error_logger report and catches every raise. Rule text
   stays out of Guardian.Rules.Server's status and crash reports: keep every callback
   (`init/1` and each `handle_*`) behind `scrubbed/1`, and keep sources out of new
   state fields or messages unless `format_status/1` redacts them. Plans and bare
   typed steps are redacted before the generic struct case, including their AST
   constants as well as canonical source. Unknown stack-frame shapes must become a
   fixed redacted frame, never pass through with their closures or argument values.
   Use `Guardian.Failure` for shared stack redaction and value-free failure labels;
   Server retains its raw-reason labels and callback catch/reraise policy.
6. Validation is whole-set and a write is refused only for errors it adds
   (`Guardian.Rules.RuleSet.new_errors/2`, ignoring lines), so broken sets stay repairable.
7. Rules fail closed: a statement that raises, or an event over its time or heap
   limit, fails the event; a table whose stored rules are invalid at boot is published
   as invalid (its events fail, other tables run) rather than refusing startup. There are
   no switches for either (`docs/changes/ingest-rules.md`, open questions 1 and 2).
8. Statement words are contextual (see `lib/guardian/ast/CLAUDE.md`).
9. Whole-set preparation validates counter plans, orders expression dependencies
   with the LOOKUP barrier and binds definition identities.
10. Compiler refuses unresolved plans and unbound LOOKUPs.
11. The activation selector retains prior dependency components on invalid reloads;
    Publisher derives prior plans from published modules, including after restart,
    without a separate metadata registry.
12. Counter responsibilities stay split as settled in the change document:
    Guardian.Counters.Store provides node-local ETS storage,
    Guardian.Counters.Client provides bounded cluster ownership,
    Guardian.Counters.Execution runs a level's counters, and
    Guardian.Aggregation provides shared mergeable operators.
13. Counter failures fail open without changing SET/UNSET's fail-closed behavior
    or skipping final UNSETs.
14. BY values and arbitrary, min/max, `_by` and `_n` states may retain sensitive
    values after UNSET.
15. Rules never retry an event or roll back counter updates: an unkeyed
    resubmission counts again, and a later rule or storage failure can leave
    earlier TRACK updates counted.
16. GUARDIAN_COUNTER_MEMORY_MB maps positive MiB to Store's byte budget.

Read the reviewed counter design in `docs/changes/ingest-rules.md` and its follow-up
change documents before changing any counter semantics.

Tests use `Guardian.Test.Rules`; its shared-server helpers require `async: false`,
while `compile_module/2` is async-safe for distinct probe modules. `Guardian.FakeS3`
checks SigV4 with its own implementation of the canonical request.
