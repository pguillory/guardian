# Rule store capabilities and lock policy

Status: complete.

Product spec impact: none. Rule writes, refusal messages, lock timing, environment
overrides and on-disk objects stay unchanged; neither product overview nor spec
needs an edit.

`Guardian.Rules.Store.local?/1` recognized the concrete folder-store module to
refuse clustered writes. Whether nodes share a store and coordinate conditional
writes is a generic store capability. `Guardian.ObjectStore` now exposes an
optional `shared?/1` callback and dispatches it with the store config, loading the
implementation before checking for the callback. Local declares false, S3 true.
Custom implementations without the callback default to true, preserving their
previous acceptance in a cluster. This declares a guarantee, without probing the
store or its network.

The remaining `Guardian.Rules.Store` contained only the rule write lock key, lease
and save margin. Those now live directly in their sole runtime caller,
`Guardian.Rules.Server`, and Store is removed. `_write.lock`, the 120 s lease and
80 s save margin, both test override keys, and the save-margin comparison with S3's
20 s write deadline are preserved. The generic lease implementation stays in
`Guardian.ObjectStore.Lock`.

The rule server refuses clustered writes using the capability instead of a
concrete module check. The existing local-folder message stays byte-identical.
Store layout/filtering, write admission, redaction, reload and publication are
unchanged.

Validation covers explicit Local/S3 and config-dependent capabilities, callback-less
custom-store compatibility, and clustered refusal for a custom unshared adapter.
The default margin-vs-deadline test moves into the server tests; existing lock,
lease, unknown-write and cluster tests remain in place.

Formatting and test compilation with warnings as errors passed. The focused
object-store and Rules server/cluster tests passed (65 tests, seed 145766), including
capability dispatch for an implementation not yet loaded on a peer.

The single full pre-commit run passed formatting and warning-free compilation;
the suite had 1 failure among 1,317 tests (3 excluded), seed 357856. The unchanged
Query.TextTest's `form/2` nested-list budget test took 626,888 microseconds against
its 100,000-microsecond wall-clock threshold. That timing flake is separate work.
The file passed alone afterwards (12 tests, seed 46253), and all three changed test
files passed again (43 tests, seed 570235). No second full run was made; committing
with that recorded failure and the passing focused reruns was authorized.
