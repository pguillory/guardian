# Rules Subsystem

Ingest-time rules: files of SET, UNSET, TRACK and LOOKUP statements, one folder per table
(`<table>/<name>.gsql`), run on each event sent through the ingest APIs before it is
stored. The design and its reviews are in `docs/changes/ingest-rules.md`; user-visible
behavior is `docs/product/spec.md` section 5.1. Read both before changing this.

Modules:

- `Rules`: the API (`lookup/1`, `run/2`, list/read/write/delete, `reload/0`). Lookups
  read one `:persistent_term` map of table to compiled module, or `{:invalid,
  message}` for a table whose stored rules fail validation.
- `Rules.RuleSet`: parses (`AST.Parser.parse_rules/1`) and validates a whole set,
  every table together, into one `Rules.Plan` per table. Pure: no reads, no state.
  `prepare/1` checks counter semantics and returns unbound candidates plus resolved
  plans; public validation and Server writes/loads use the same preparation.
  Only resolved plans have `resolved?: true`.
- `Rules.Step`: typed per-kind inputs and read derivation.
- `Rules.Validation`: scalar, counter aggregate, interval and FROM checks.
- `Rules.DependencyGraph`: deterministic flat ordering and dependency levels with
  the explicit LOOKUP barrier. Resolved plans retain both; levels rebuild after binding.
- `Rules.Resolution`: immutable target definitions and fixed-point invalidity.
- `Rules.CounterDefinition`: immutable target metadata and window/bucket sizes.
- `Rules.Activation`: pure coherent reload selection, used by Server.
- `Rules.Compiler`: a plan into a generated module from a fixed template, with the
  statements as escaped literals. Generated `plan/0` exposes the exact resolved
  plan for reload/restart recovery, bounded and reclaimed with the module pool.
  No rule text becomes code. Unresolved plans and unbound LOOKUPs cannot compile.
- `Rules.Runtime`: the dispatcher called by generated modules (reads, SET, UNSET,
  failures), threading a `Rules.RowIndex` through dependency levels. Internal
  TRACK/LOOKUP dispatch uses bound identities and aggregate defaults on failure.
- `Rules.Event`: private Unix/monotonic arrival coordinates outside the row; Engine
  captures them before validation. Runner adds a per-event Cluster context on worker
  entry, sharing one batch atomics budget across replacement workers.
- `Rules.CounterRuntime`: expands each counter into bucket key machines and
  combines their states chronologically after one shared run_nested per level.
  Any failed bucket defaults its whole statement; missing buckets use empty states.
  Whole intersecting buckets bias reads toward overcount: floor((arrival-W)/B)
  through floor(arrival/B), B=ceil(W/3). Native count increments and generic
  gets/merge/CAS use their returned state, never a post-update read. Only definite
  CAS conflicts retry, at most three total attempts. Zero-count deltas and unchanged
  generic states skip mutation. TTLs count down to one anchored monotonic expiry
  derived from bucket_end+W; transit can still delay physical expiry at the owner.
- `Rules.RowIndex`: the event's row, with a trie of its keys by lowercase object path
  and a map of lowercase spelling to present keys, so a statement costs what it
  touches rather than a pass over every column. Its tests check it against the old
  scan, reimplemented in the test.
- `Rules.Runner`: runs a batch in a worker under the heap limit, 1 s per event.
- `Rules.Store` (`Local`, `S3`): the files. `Rules.Lock`: the write lock in the store.
- `Rules.Config`: chooses the store from the environment.
- `Rules.Server`: startup load, reload, poll, writes, activation, the module pool.

Rules to keep:

1. Nothing reads the store per event. The ingest path sees only the published map.
2. Never load a module name twice while anything can call it. Compile into a free
   pool name, publish the whole map at once only after every changed table compiled,
   and reclaim retired names only after the grace period and a successful
   `:code.soft_purge/1`. Never `:code.purge/1` a published or retired module.
3. Atoms stay bounded: module names come only from `Rules.Compiler`'s pool. Never
   create an atom from rule text, a table name or a store key.
4. Credentials never leave `Rules.Store.S3` or `Rules.Config`: they live only in a
   closure, requests carry an MFA for signing, and every store call returns a reason
   naming only a kind. Never log or return a response body, header, request, or a
   caught exception's message from a store call.
5. Rule failures are logged by file, line and kind only, never a value (event values
   can be the very secret an UNSET removes). Validation errors are logged the same
   way, never by message: a message can quote rule text. The rule worker reports
   heap kills without the error_logger report and catches every raise. Rule text
   stays out of Rules.Server's status and crash reports: keep every callback
   (`init/1` and each `handle_*`) behind `scrubbed/1`, and keep sources out of new
   state fields or messages unless `format_status/1` redacts them. Plans and bare
   typed steps are redacted before the generic struct case, including their AST
   constants as well as canonical source.
6. Validation is whole-set and a write is refused only for errors it adds
   (`Rules.RuleSet.new_errors/2`, ignoring lines), so broken sets stay repairable.
7. Rules fail closed: a statement that raises, or an event over its time or heap
   limit, fails the event; a table whose stored rules are invalid at boot is published
   as invalid (its events fail, other tables run) rather than refusing startup. There are
   no switches for either (`docs/changes/ingest-rules.md`, open questions 1 and 2).
8. Statement words are contextual (see `lib/ast/CLAUDE.md`). Whole-set preparation
   validates counter plans, orders expression dependencies with the LOOKUP barrier
   and binds definition identities. Compiler refuses unresolved plans and unbound
   LOOKUPs. The activation selector retains prior dependency
   components on invalid reloads; Server derives prior plans from published
   modules, including after restart, without a separate metadata registry.
   Where TRACK counter state lives is settled in the change document:
   Counters.Store provides node-local ETS storage,
   Counters.Cluster provides bounded cluster ownership,
   and Counters.Aggregate provides pure mergeable operators. Counter failures fail
   open without changing SET/UNSET's fail-closed behavior or skipping final UNSETs.
   BY/min/max state may retain sensitive values after UNSET; no event retry or
   rollback is allowed. GUARDIAN_COUNTER_MEMORY_MB maps positive MiB to Store's
   byte budget. Read the reviewed design before changing counter semantics.

Tests use `RulesTestHelper` (shared server, so `async: false`) and `FakeS3`, which
checks SigV4 with its own implementation of the canonical request.
