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
  `prepare/1` checks counter semantics and returns unbound candidates (locally valid,
  before LOOKUP resolution) plus resolved plans; public validation and Server
  writes/loads use the same preparation.
  Only resolved plans have `resolved?: true`.
- `Guardian.Rules.Step`: typed per-kind inputs and read derivation.
- `Guardian.Rules.Validation`: scalar, counter aggregate, interval and FROM checks.
- `Guardian.Rules.DependencyGraph`: deterministic flat ordering and dependency levels with
  the explicit LOOKUP barrier. Plans hold only the flat steps; Compiler derives the
  levels from them once per compiled module.
- `Guardian.Rules.Resolution`: immutable target definitions and fixed-point invalidity.
  Resolved plan hashes use deterministic ETF, so they match across VM starts.
- Counter definitions are `Guardian.Counters.Definition`s (counters layer): the
  single owner of counter identity, operator, window/bucket sizes and grouping
  arity. Step builds one for a parsed TRACK (identity from table, field and source
  digest; the LAST interval with its 365-day bound); Validation checks its operator
  and window before plan construction, and LOOKUPs and Runtime reuse it.
  `Guardian.Rules.Resolution.hash_term/1` owns the target's struct-shaped hash
  input, under the frozen `Guardian.Rules.CounterDefinition` format tag; renaming
  that tag resets every dependent plan hash.
- `Guardian.Rules.Publisher`: synchronous activation/publication and generated-module
  pool ownership, called inside Server's callbacks. Publishes each table's current
  preparation result; its state contains only free names and retired statuses,
  never plans, sources or diagnostics. Reclamation timers target Server.
- `Guardian.Rules.Compiler`: a plan into a generated module from a fixed template, with the
  execution levels, derived from the flat steps at compile time, as one shared escaped
  literal, plus `table/0` and `hash/0`. No rule text becomes code. Unresolved plans
  and unbound LOOKUPs cannot compile.
- `Guardian.Rules.Runtime`: the dispatcher called by generated modules (reads, SET, UNSET,
  failures), threading the flat row map through dependency levels. Internal
  TRACK/LOOKUP dispatch uses bound identities and aggregate defaults on failure.
  For each level, Runtime prepares every counter statement as skipped, failed or
  an op, runs the ops with the event's arrival and counter context through
  `Guardian.Counters.Execution.run_counters/3` (the
  counters layer: buckets, rounds, routing, combination;
  `lib/guardian/counters/AGENTS.md`), writes each result into its field and logs
  `{:error, kind}` results by file and line (`docs/changes/counter-execution-layer.md`).
  Failed statements get their operator's missing result,
  `Aggregation.default(Definition.aggregation(definition))`.
- `Guardian.Rules.Event`: what a compiled module gets besides the row: the event's
  private `Guardian.Counters.Arrival` (Unix/monotonic arrival coordinates outside
  the row, which Engine captures before validation) and the typed Counters.Context
  that Runner adds under Event.counters on worker entry, sharing one batch atomics
  budget across replacement workers.
- `Guardian.Rules.Runner`: runs a batch in a worker under the heap limit, 1 s per event.
- `Guardian.Rules.Config`: chooses the store from the environment.
- `Guardian.Rules.Server`: process, startup load, reload, locked writes and
  admission. Nothing re-reads the store on a timer: rules change only through writes,
  which reload every connected node (`docs/changes/rules-no-poll.md`). Owns rule lock
  policy (key, lease and save margin). The store is a
  `Guardian.ObjectStore` (`lib/guardian/object_store/AGENTS.md`): S3 or a local folder.
  Both list every object; Server and `Guardian.Rules.list_rules/1` apply the rule
  layout (`Guardian.Rules.RuleSet.parse_key/1`). The write lock is a
  `Guardian.ObjectStore.Lock`, tried once: a held lock returns `{:error, :busy}`, with
  no retry in Rules (the MCP tools retry briefly); stores declaring
  `ObjectStore.shared?/1` false refuse writes with peers connected. Holds Publisher's
  pool value and forwards reclamation messages.

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
5. An event over its limit tells the sender and logs nothing. Validation errors are
   not logged: a message can quote rule text, and an invalid table already shows in
   its events' error and the rule tools' replies, so don't add a log line for it.
   The rule worker reports heap kills without the error_logger report. It catches no
   raise: a rule crash fails the request. Guardian.Rules.Server's formatted status is
   not redacted (CONTRIBUTING.md, "Logging"), and its callbacks crash as they are.
6. Validation is whole-set and a write is refused only for errors it adds
   (`Guardian.Rules.RuleSet.new_errors/2`, ignoring lines), so broken sets stay repairable.
7. Rules fail closed: a statement that raises fails the request, an event over its
   time or heap limit fails the event; a table whose stored rules are invalid is
   published as invalid (its events fail, other tables run) rather than refusing
   startup. There are no switches for either (`docs/changes/ingest-rules.md`, open questions 1 and 2).
8. Statement words are contextual (see `lib/guardian/ast/AGENTS.md`).
9. Whole-set preparation validates counter plans, orders expression dependencies
   with the LOOKUP barrier and binds definition identities.
10. Compiler refuses unresolved plans and unbound LOOKUPs.
11. Activation keeps no history: boot, reload and writes all publish each
    table's current preparation result, so an invalid table (or one whose LOOKUP
    reads an invalid table's counter) fails its events and never keeps its last
    good rules (`docs/changes/invalid-rules-fail-events.md`).
12. Counter responsibilities stay split as settled in the change document:
    Guardian.Counters.Store provides node-local ETS storage,
    Guardian.Counters.Client provides bounded cluster ownership,
    Guardian.Counters.Execution runs a level's counters, and
    Guardian.Aggregation provides shared mergeable operators.
13. An unreachable counter store fails open, without changing the fail-closed behavior
    of anything that raises or skipping final UNSETs. Keep that path simple.
14. BY values and arbitrary, min/max, `_by` and `_n` states may retain sensitive
    values after UNSET.
15. Rules never retry an event or roll back counter updates: an unkeyed
    resubmission counts again, and a later rule or storage failure can leave
    earlier TRACK updates counted.
16. GUARDIAN_COUNTER_MEMORY_MB maps positive MiB to Store's byte budget.

Read the reviewed counter design in `docs/changes/ingest-rules.md` and its follow-up
change documents before changing any counter semantics.

Tests use `Guardian.Test.Rules`: `with_rules/1` is async-safe on a test's own table,
`restart_server/2` and `publish_module/2` require `async: false`, and `compile_module/2`
is async-safe for distinct probe modules. `Guardian.Test.FakeS3`
checks SigV4 with its own implementation of the canonical request.
