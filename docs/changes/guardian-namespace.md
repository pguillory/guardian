# Guardian module namespace

Status: complete.

Guardian's generic top-level modules collided with applications embedding the
event store. All owned modules and protocols now use `Guardian.*`, including
`Guardian.Web.*`, utilities, the application callback, test helpers and generated
rule modules. References, RPC targets, native NIF entry points, examples and
subsystem instructions follow that convention. External protocols keep their own
prefix on generated implementations. There are no old-name forwarding modules.

Existing source and test paths stay in place to keep this change focused on names;
moving them under a matching `guardian/` directory is separate follow-up work.

The Mix application remains `:guardian`. Existing scalar configuration keys,
environment variables, release/node names, directories and file names already
belong to Guardian and remain unchanged. This change does not add configurable
multiple instances or a different startup lifecycle for embedded applications.

Product spec impact: sections 4.4 and 4.5 use the qualified Elixir entry points,
describe full-restart compatibility and note the diagnostic name change below.
Other module references are qualified throughout. Overview impact: none.

## Persisted and serialized data audit

1. Segments: `Guardian.Storage.SegmentFile` writes nine big-endian integer header
   words, packed key/count/size columns and native packed value columns. Segment
   structs exist only in processes; no struct or module name is serialized to a
   `.seg` file. File names stay `{table}.{segment_id}.seg`. The pre-change golden
   fixture `test/fixtures/segment_file.seg` is unchanged and checks both old-file
   reads and byte-identical new writes. No migration is needed.
2. Counters and ETF: counter entries live only in private ETS, including Hypex
   values from the unchanged dependency. Owner hashing uses explicit tagged
   encoding. The two production `term_to_binary` calls hash rule identities:
   file/line/source tuples, and LOOKUP target definition structs. The latter's
   hash can change with its struct module, but plans are rebuilt in memory and
   neither hash nor counter state is written to disk. Restarts lose advisory
   counters as before. No production `binary_to_term` reader exists. The test-only
   `test/fixtures/column_nif_outputs.etf` contains packed outputs and scalar/list
   expectations, without module names, and is unchanged.
3. Rule store: both local and S3 stores hold `.gsql` source and `_write.lock` JSON,
   never parsed AST, plan or store structs. Existing text is parsed and compiled
   under the new names at boot. Paths, lock format and configuration do not change.
4. Compiled rules: the bounded `Guardian.Rules.Compiled.M0` through `M1023` pool
   is generated with `Module.create/3` in the VM. Compiled BEAM/plan data is not
   persisted; startup regenerates it from rule source.
5. ETS, persistent terms, registered processes and native resources: module-based
   names now follow `Guardian.*`, including the explicit rule failure-log table.
   They are VM-local and recreated by a full restart. NIF module/resource identity
   changes require a new VM; hot-code upgrades are unsupported for this transition.
6. Deployment volume: the source-defined durable formats are segments, rule text
   and the JSON lock, alongside ignored temporary writes. Their formats/paths do
   not change. Production contents were not independently inspected or modified.
   This audit covers Guardian's formats, not arbitrary files an operator may have
   stored on the volume.

Deployment must restart the full release on every node. During a rolling deploy,
mixed old/new builds cannot reliably exchange RPC calls, closures or structs;
distributed queries can fail until all nodes finish. No compatibility with old
in-memory terms is promised. Deployment is separate from this code change.

Existing event values are untouched. New failure-kind diagnostics that inspect an
owned exception module name now contain `Guardian.*`, including per-event ingest
errors and API errors that name an exception. Old built-in table rows keep the old
names; saved queries filtering those strings may need both spellings.

## Validation

The namespace ownership test checks compiled application modules and the exact
external protocol implementations, plus the generated pool name. Existing golden
fixtures, rule store/compiler tests, real peer tests, configuration tests and API
tests exercise the compatibility boundaries. The final pre-commit runs formatting,
compilation with warnings as errors and the full suite after independent code review.

Passed: 115 focused tests, then the final pre-commit with 1,168 tests, zero failures
and three excluded large tests. Independent Claude and Codex plan/code reviews
approved both changes. The existing `.seg` and ETF fixtures were not regenerated.
