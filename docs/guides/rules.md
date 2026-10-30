# Rules and rule storage

Rules are files named `<table>/<name>.gsql` (the language is in the
[product spec](../product/spec.md#51-rules)). Guardian reads them from one store: a
local folder, or an S3-compatible bucket such as Cloudflare R2. It loads every rule at
startup, after each write through the MCP rule tools, and once a minute, and never
reads the store while ingesting. If the store is misconfigured, or unreachable or
rate-limiting at startup (after about a minute of retries), Guardian refuses to start
rather than run without its rules.

## Counters with TRACK and LOOKUP

Create `logins/rate.gsql`, or use MCP `write_rule` with `table: logins`, `name: rate`
and this source:

```sql
TRACK logins_last_hour = count() BY ip LAST '1h';
LOOKUP previous_logins = logins_last_hour BY ip;
SET busy = logins_last_hour >= 50;
UNSET password
```

Send events through HTTP or MCP `send_events`, requesting
`return_keys: ["logins_last_hour", "previous_logins", "busy"]`. The 50th login for
an IP returns 50, 49 and true. The producer decides what to do with that signal.
Guardian stores the computed fields and queries read those historical values.

Field names are flat and case-sensitive. `UNSET password` removes the column
`password` and nothing else: not `Password`, and not `password.hash`. When a rule
removes a secret, name every column that can hold it (`UNSET card.number`,
`UNSET users..email`), in each spelling senders use. `SET user = 'redacted'` writes
`user` and leaves `user.name` stored. A rule can name only columns made of letters,
digits, underscores and dots, so it cannot remove a key such as `headers.x-api-key`
or one it does not know in advance: keep those out of the event before sending it.

A row holding both `user` and `user.name` has no single JSON form, so `return_keys:
["user"]` reads null even though `user` was stored. A sender can cause this for a
rule's output by sending a nested key under its name, so a caller must not treat a
null output as a decision.

TRACK includes the current event; LOOKUP reads before that event's updates. See the
[rule execution contract](../product/spec.md#513-running) for dependencies, ordering
and concurrency.

For cross-table reads, put this in `payments/risk.gsql`:

```sql
LOOKUP recent_logins = logins_last_hour FROM logins BY client_ip;
SET needs_review = recent_logins > 100
```

The target must exist and BY arity must match. Use the same value types and order
as the target's grouping; omit BY for a global counter. WHERE false or null skips
the statement and preserves its incoming field. Apply counter statements
unconditionally, or explicitly set a safe skipped value, when a caller-supplied
output would be untrustworthy.

The [product spec's counter contract](../product/spec.md#514-counters) defines supported
aggregates and missing results (item 1), typed groups (item 2), LAST and
arrival-time buckets (item 3), failure handling and call budgets (items 5–6), and
state loss and eviction (item 7). Counters are advisory signals; keep node clocks
synchronized for their arrival-time windows.

Set [GUARDIAN_COUNTER_MEMORY_MB](../reference/configuration.md) and restart
to change the resident counter memory target. High-cardinality groups compete for
this shared budget.

UNSET removes fields from stored events, not from counter memory: BY keys and the
values kept by arbitrary, min/max and the _by and _n forms can retain sensitive
inputs and cross the trusted peer network until expiry/eviction. Avoid putting
secrets in those expressions.

### Editing and retrying counters

Before editing a live counter, check the
[counter identity contract](../product/spec.md#514-counters) (item 4) and
[reload contract](../product/spec.md#513-running) (item 6): they define which edits
reset counts or preserve them, and how invalid dependency components retain their
previous good plans.

Writes validate the entire rule set. To change grouping arity or rename/delete a
referenced TRACK, add a new named TRACK, retarget its LOOKUPs (with matching BY),
then delete the old TRACK. Alternatively remove dependents first. A one-file change
that strands a LOOKUP is refused. Duplicate definitions must be removed or updated
without leaving conflicting definitions of one output field.

For retrying an ingest, use the [batch retry examples](../reference/api.md#retrying-a-batch)
and [idempotency contract](../product/spec.md#5-ingestion) (item 9). A later rule or
storage failure can leave earlier TRACK increments; there is no rollback.
Unkeyed resubmissions count again; a matching keyed retry returns only a receipt,
without decision or counter fields ([counter contract](../product/spec.md#514-counters),
item 5).

## A local folder (the default)

With no rule settings, rules live in `<GUARDIAN_DATA_DIR>/rules`; `GUARDIAN_RULES_DIR`
moves them. Files edited there by hand are picked up within a minute and checked like
any write. If a table's rules fail the check, a running node keeps that table's last
good rules and logs the errors; a node starting up rejects that table's events until
the rules are fixed. Any `.gsql` file in a table's folder counts, so a stray or
misnamed one (`logins/README.gsql`) fails that table. A `.gsql` file anywhere else is
reported as an error too: `logins/old/rate.gsql` fails `logins`, while `rate.gsql` at
the top names no table, so it fails none. Other files are ignored, as are names
starting with `.`. Every file in the folder is read on each check, and a folder with
more than 20,000 entries fails to load, so keep only rules there: Guardian refuses to
start if the folder is `GUARDIAN_DATA_DIR`, contains it, or is inside its `segments`
folder.

A folder suits one node only. A node that is connected to others refuses rule writes
to a local folder, since each node would have its own copy.

## An S3-compatible bucket

A cluster needs a bucket, so that every node reads the same rules. Set all four of:

| Variable | Meaning |
| --- | --- |
| `GUARDIAN_RULES_S3_BUCKET` | The bucket name. |
| `GUARDIAN_RULES_S3_ENDPOINT` | The S3 endpoint, `https://<host>` with no path (for R2, `https://<account id>.r2.cloudflarestorage.com`). `http://` is accepted only for a server on the same machine: `localhost`, an address in 127.0.0.0/8, or `[::1]`. |
| `GUARDIAN_RULES_S3_ACCESS_KEY_ID` | An access key that can list, read, write and delete objects in the bucket. |
| `GUARDIAN_RULES_S3_SECRET_ACCESS_KEY` | Its secret. Keep it with your other secrets (on Fly, as a Fly secret). |

Optionally `GUARDIAN_RULES_S3_REGION` (default `auto`, right for R2) and
`GUARDIAN_RULES_S3_PREFIX` (default none; a prefix must end in `/`, such as `rules/`,
and use only letters, digits and `. _ ~ / -`). Guardian lists everything under the
prefix and gives up past 20 pages (about 20,000 objects), so give rules their own
bucket or prefix.
Setting only some of the four, or the bucket and `GUARDIAN_RULES_DIR` together,
refuses startup. Requests use path-style URLs and SigV4 signing.

The store must support conditional writes (`If-None-Match: *` and `If-Match`), which
the cluster-wide write lock depends on. R2 and current Amazon S3 do. Give the key
access to this bucket only: anyone holding it can change the rules without the API
key, though Guardian still checks what it loads.

To rotate the key, create a new one, set both values in one restart, then revoke the
old one.

## Switching an existing deployment to a bucket

1. Deploy the release first with the default local folder, so behavior is unchanged
   and a rollback is a plain one.
2. Check the credentials from the deployment's own network, including the
   conditional writes. With a recent AWS CLI v2 (`--endpoint-url` set to the
   endpoint, `--bucket` to the bucket, and the key in `AWS_ACCESS_KEY_ID` and
   `AWS_SECRET_ACCESS_KEY`):

   ```sh
   aws s3api put-object --key probe --body /dev/null --if-none-match '*'   # succeeds
   aws s3api put-object --key probe --body /dev/null --if-none-match '*'   # fails: 412
   etag=$(aws s3api head-object --key probe --query ETag --output text)
   aws s3api put-object --key probe --body /dev/null --if-match "$etag"     # succeeds
   aws s3api delete-object --key probe
   aws s3api list-objects-v2 --max-items 1
   ```

   Use the prefix in the key if you set one (`rules/probe`).
3. Copy any rules already in the local folder into the bucket, keeping the
   `<table>/<name>.gsql` layout under the prefix. The switch reads only the bucket, so
   rules left behind would stop applying.
4. Set all the bucket settings together, in one restart (on Fly, one
   `fly secrets set` with every value).
5. Check that `list_rules` shows the rules.

To roll back, remove all the bucket settings together, again in one restart. The local
folder is still there, but it holds only the rules it had before the switch, so copy
back any written since.
