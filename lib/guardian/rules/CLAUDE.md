# Rules Subsystem

Ingest-time rules: files of SET, UNSET, TRACK and LOOKUP statements, one folder per table
(`<table>/<name>.gsql`), run on each event sent through the ingest APIs before it is
stored. The design and its reviews are in `docs/changes/ingest-rules.md`; user-visible
behavior is `docs/product/spec.md` section 5.1. Read both before changing this.

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
- `Guardian.Rules.CounterDefinition`: immutable target metadata, resolved shared
  aggregate configuration and window/bucket sizes. TRACK steps receive their
  definition after semantic validation; LOOKUPs and Runtime reuse it. `hash_term/1`
  owns the target's struct-shaped hash input, excluding derived configuration.
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
- `Guardian.Rules.Event`: private Unix/monotonic arrival coordinates outside the row; Engine
  captures them before validation. Runner adds a typed Counters.Context under
  Event.counters on worker entry, sharing one batch atomics budget across
  replacement workers.
- `Guardian.Rules.CounterRuntime`: expands each counter into bucket key machines and
  combines their states chronologically after one shared run_nested per level.
  Any failed bucket defaults its whole statement; missing buckets use empty states.
  Whole intersecting buckets bias reads toward overcount: floor((arrival-W)/B)
  through floor(arrival/B), B=ceil(W/3). Native count increments and generic
  gets/merge/CAS use their returned state, never a post-update read. Only definite
  CAS conflicts retry, at most three total attempts. Zero-count deltas and unchanged
  generic states skip mutation. TTLs count down to one anchored monotonic expiry
  derived from bucket_end+W; transit can still delay physical expiry at the owner.
- `Guardian.Rules.RowIndex`: the event's row, with a trie of its keys by lowercase object path
  and a map of lowercase spelling to present keys, so a statement costs what it
  touches rather than a pass over every column. Its tests check it against the old
  scan, reimplemented in the test.
- `Guardian.Rules.Runner`: runs a batch in a worker under the heap limit, 1 s per event.
- `Guardian.Rules.Store`: the rule store's policy (the lock key, lease and save
  margin). The store itself is a `Guardian.ObjectStore` (`lib/guardian/object_store/CLAUDE.md`):
  `Guardian.ObjectStore.S3`, or the rule folder `Guardian.Rules.Store.Local`, which lists
  and accepts only rule keys. The write lock is a `Guardian.ObjectStore.Lock`.
- `Guardian.Rules.Config`: chooses the store from the environment.
- `Guardian.Rules.Server`: process, startup load, reload, poll, locked writes and
  admission. Holds Publisher's pool value and forwards reclamation messages.

Rules to keep:

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
8. Statement words are contextual (see `lib/guardian/ast/CLAUDE.md`). Whole-set preparation
   validates counter plans, orders expression dependencies with the LOOKUP barrier
   and binds definition identities. Compiler refuses unresolved plans and unbound
   LOOKUPs. The activation selector retains prior dependency
   components on invalid reloads; Publisher derives prior plans from published
   modules, including after restart, without a separate metadata registry.
   Where TRACK counter state lives is settled in the change document:
   Guardian.Counters.Store provides node-local ETS storage,
   Guardian.Counters.Client provides bounded cluster ownership,
   and Guardian.Aggregation provides shared mergeable operators. Counter failures fail
   open without changing SET/UNSET's fail-closed behavior or skipping final UNSETs.
   BY values and arbitrary, min/max, `_by` and `_n` states may retain sensitive
   values after UNSET; no event retry or
   rollback is allowed. GUARDIAN_COUNTER_MEMORY_MB maps positive MiB to Store's
   byte budget. Read the reviewed design before changing counter semantics.

Tests use `Guardian.RulesTestHelper` (shared server, so `async: false`) and `Guardian.FakeS3`, which
checks SigV4 with its own implementation of the canonical request.
