# Simplify the rule store and its tests

Status: implemented.

Preston's decision: this area was overengineered. Prefer deleting to designing.

## Product spec impact

`docs/product/spec.md`: MCP tools item 3 (a failed save says it may have been saved),
5.1.5 item 3 (the refusal on a local folder goes), 5.1.6 (any store failure at startup
is retried; only invalid settings refuse), and known limitations item 7 (no lease check
remains).

## What changed

1. `Guardian.Test.FakeS3` is gone. Rule tests use one store, the folder in the run's
   fresh data directory, and each its own tables, so they don't restart the rule server
   to swap stores.
2. S3 access uses `req_s3`. The hand-written XML and date parsing, write deadline,
   failure classification and page bound go. Credentials are plain config: the closure,
   signing MFA and Inspect implementation go, so a crash report can show the secret.
3. A failed store call is `:not_found`, `:precondition_failed` or a message, and an error
   to the caller with the lock released. There is no "unknown outcome" and no lease
   margin before a save. A failed save says it may have been saved.
4. Boot retries any failed store call forever and logs it. It needs nothing from the
   error but that it failed, so wrong credentials or a missing bucket now retry visibly
   instead of refusing startup. Invalid settings still refuse.
5. The refusal of rule writes on a local folder with other nodes connected goes, with
   `shared?`. Cluster tests share the local folder. A local folder's lock was
   `:global` on this node only, so it did not hold across peers; it now spans connected
   nodes, and `lock_cluster_test.exs` fails against the old lock.
6. S3 mode has no automated test. CONTRIBUTING.md has the by-hand console check, run
   when `ObjectStore` changes. Keys are unaffected: the object layout, percent-encoding
   and the conditional headers are as before.
