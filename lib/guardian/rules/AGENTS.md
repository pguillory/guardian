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
- `Guardian.Rules.Publisher`: synchronous activation/publication, called inside
  Server's callbacks, with no state. Publishes each table's current preparation
  result, replacing each changed table's module in place: compile all, soft-purge
  all, `:code.atomic_load/1`, publish. `purge_for/1` is the pre-save check writers
  run on every node.
- `Guardian.Rules.Compiler`: a plan into a generated module's binary (not loaded) from a
  fixed Erlang abstract-format template, with the execution levels, derived from the
  flat steps at compile time, as one shared literal, plus `table/0` and `hash/0`.
  `module_name/1` names each table's one module. No rule text becomes code. Unresolved plans
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
  that Runner adds under Event.counters as each event's rules start.
- `Guardian.Rules.Runner`: runs a batch's rules in the caller, one row at a time, with no
  limit of its own.
- `Guardian.Rules.Config`: chooses the store from the environment.
- `Guardian.Rules.Server`: process, startup load, reload, locked writes and
  admission. Nothing re-reads the store on a timer: rules change only through writes,
  which reload every connected node (`docs/changes/rules-no-poll.md`). Owns rule lock
  policy (key and lease). The store is a
  `Guardian.ObjectStore` (`lib/guardian/object_store/AGENTS.md`): S3 or a local folder.
  Both list every object; Server and `Guardian.Rules.list_rules/1` apply the rule
  layout (`Guardian.Rules.RuleSet.parse_key/1`). The write lock is a
  `Guardian.ObjectStore.Lock`, tried once: a held lock returns `{:error, :busy}`, with
  no retry in Rules (the MCP tools retry briefly). Before saving, asks every node's
  Server to run `Publisher.purge_for/1`; releases the lock right after the save.

## Rules to keep

1. Nothing reads the store per event. The ingest path sees only the published map.
2. Never kill a process running rule code. Load a rule module only after a successful
   `:code.soft_purge/1` of its old code, and only with `:code.atomic_load/1` (which
   refuses old code rather than purging it); if a purge fails, load nothing. Never
   `:code.purge/1` or `:code.load_binary/3` a rule module. Only Rules.Server loads
   rule modules, and a write checks every node with `purge_for/1` before saving.
3. Atoms grow only with table names: a table's module name comes only from
   `Guardian.Rules.Compiler.module_name/1`, on a validated table name. Never create an
   atom from rule text or a store key. A deleted table's module stays loaded, uncalled.
4. A failed store call is an error to the caller, with the lock released; only boot
   retries, and it retries any failure.
5. Validation errors are not logged: a message can quote rule text, and an invalid
   table already shows in its events' error and the rule tools' replies, so don't add
   a log line for it. Runner catches no raise and limits nothing: a rule crash fails
   the request. Guardian.Rules.Server's formatted status is not redacted
   (CONTRIBUTING.md, "Logging"), and its callbacks crash as they are.
6. Validation is whole-set and a write is refused only for errors it adds
   (`Guardian.Rules.RuleSet.new_errors/2`, ignoring lines), so broken sets stay repairable.
7. Rules fail closed: a statement that raises fails the request; a table whose
   stored rules are invalid is published as invalid (its events fail, other tables
   run) rather than refusing startup. There are no switches for either
   (`docs/changes/ingest-rules.md`, open questions 1 and 2).
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

Tests use the one rule store, each on its own tables, through `Guardian.Test.Rules`:
`with_rules/1` is async-safe on a test's own table, `plant_file/2` of an invalid file,
`stop_server/0` and `restart_server/0` require `async: false`, and
`compile_module/2` is async-safe for distinct probe modules, and
`park_in_rules_module/1` (a process parked in a table's module, the one way to reach
the too-recent refusal) for a test's own table.
