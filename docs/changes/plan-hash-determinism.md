# Deterministic resolved plan hashes: plan-hash-determinism

Status: implemented and validated.

Product spec impact: none. Overview impact: none. No disk format, supervision or
counter changes.

A resolved plan's hash covers its base hash and, for each LOOKUP, the target's
`CounterDefinition.hash_term/1` map. That map has atom keys, and since OTP 26 the
plain external term format orders a small atom-keyed map by atom-table index, which
depends on the order the VM happened to create those atoms. The same rule source
therefore gave different resolved hashes under `mix run --no-start` and a normal
start. Base hashes (lists of file, line and source tuples) and counter identity
digests (SHA-256 of canonical source) contain no maps and were already stable.

Resolution now encodes the hash input with `:erlang.term_to_binary/2`'s
`:deterministic` option, which sorts map keys, as Guardian.Counters.Store and
Guardian.Web.IngestIdempotency already do. The input itself is unchanged. OTP
guarantees deterministic encodings only within one OTP major release, so moving to
another OTP major may change these hashes once.

Effect: resolved hashes of plans with a LOOKUP change value once. Nothing persists
them or exchanges them between nodes; the only consumer is Guardian.Rules.Publisher's
in-VM check for reusing a compiled module, and a release upgrade is a full restart.
Plans without a LOOKUP keep their base hash, and counter identities, keys and state are
unchanged. This supersedes the note in `counter-definition-preparation.md` that
stabilizing hashes across VM starts was separate work.

Validation: before the change, one rule set's resolved hash differed between
`mix run --no-start` and a normal start, while the deterministic encoding gave the
same value in both. The counter-plan tests that re-derived resolved hashes with the
plain encoding inside the test VM now pin the deterministic resolved hashes as fixed
constants beside the existing base-hash and identity constants. These are baselines
for the supported OTP major, not an executed cross-VM test. Temporarily removing
`:deterministic` made both pinned resolved-hash tests fail. A Claude and a Codex
reviewer approved the plan and the change. No deployment or
production verification is included.
