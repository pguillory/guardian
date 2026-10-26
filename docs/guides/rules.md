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

TRACK updates and includes the current event; LOOKUP only reads. All LOOKUPs finish
before any TRACK on that event, even if files put TRACK first. SET dependencies run
where needed and all UNSETs run last. A LOOKUP input or condition cannot depend on
a TRACK result, even through SETs. Other events can update between reads; there is
no global snapshot.

For cross-table reads, put this in `payments/risk.gsql`:

```sql
LOOKUP recent_logins = logins_last_hour FROM logins BY client_ip;
SET needs_review = recent_logins > 100
```

The target must exist and BY arity must match. Grouping uses exact typed ordered
values: integer 1, float 1.0 and string '1' are different, and null is a valid group.
Omit BY for a global counter. WHERE false or null skips the statement and preserves
its incoming field. Apply counter statements unconditionally, or explicitly set a
safe skipped value, when a caller-supplied output would be untrustworthy.

TRACK supports every query aggregate, with the same arguments, and gives what that
aggregate gives over the window's events in a query: count() counts all matching
events, count_distinct uses approximate HyperLogLog precision 8, sum/avg skip
non-numbers, min/max skip null and use query ordering, and so on. Empty or failed
counters return the aggregate's result over no rows: 0 for count, count_if and
count_distinct, true for all, null otherwise (sum included). A top-N counter whose
events disagree on n returns null. Scalars are allowed in arguments, BY and WHERE;
nested aggregates are not.
The [product spec](../product/spec.md#51-rules) gives numeric and dependency details.

LAST takes a positive integral total interval in s/m/h/d/w notation, up to 365 days.
Windows use private arrival metadata captured before validation, never a client's
timestamp. Guardian adds no stored timestamp. Keep node clocks synchronized.
Window W uses buckets B=ceil(W/3), reading up to four whole intersecting buckets:
a 30-minute window can include almost 40 minutes. The oldest-bucket overcount bias
does not prevent undercounts from approximation or lost state. Each bucket expires
at bucket_end+W; updates pass the remaining TTL, though transit and queues can delay
physical expiry. An event delayed past that expiry skips its update and defaults.

Counters live in memory on one Guardian owner per definition/group, with all buckets
together. Restarts, node joins/leaves, partitions, divergent membership and eviction
can lose or split counts. No persistence, replication, backfill, uncertain-write
retry or failover is provided. A failed operation defaults the entire statement,
then SETs and final UNSETs continue; SET/UNSET failures still reject the event.
Calls have a 50 ms limit, a 100 ms event phase and a shared 250 ms failed-wait batch
allowance; suspect owners cool down for one second. Healthy calls refund the batch
allowance, so a large batch can still take time. Counters are advisory signals.

Set GUARDIAN_COUNTER_MEMORY_MB to a positive integer in MiB (default 64) and restart
to change the resident counter memory target. Empty, zero, negative and non-integer
values refuse startup. The budget excludes mailboxes, temporary copies and the
rest of the VM. Housekeeping runs about every second, so writes can temporarily
overshoot. It reclaims expired keys, then evicts live buckets through a sampled
earliest-expiry cutoff; tied expiries can discard every live bucket. High-cardinality groups compete for this shared budget.

UNSET removes fields from stored events, not from counter memory: BY keys and the
values kept by arbitrary, min/max and the _by and _n forms can retain sensitive
inputs and cross the trusted peer network until expiry/eviction. Avoid putting
secrets in those expressions.

### Editing and retrying counters

The canonical TRACK definition identifies the state. Changing its name, aggregate,
expressions, WHERE or LAST starts fresh. Moving identical text to another file or
changing comments/whitespace preserves counts. Identical copies count only once.
Old definitions disappear by expiry/eviction; old stored results are unchanged.

Writes validate the entire rule set. To change grouping arity or rename/delete a
referenced TRACK, add a new named TRACK, retarget its LOOKUPs (with matching BY),
then delete the old TRACK. Alternatively remove dependents first. A one-file change
that strands a LOOKUP is refused. Duplicate definitions must be removed or updated
without leaving conflicting definitions of one output field.

On reload, valid definitions and LOOKUP bindings switch atomically on each node.
If a table is invalid, the entire component linked by old or new LOOKUP dependencies
keeps its previous good plans, even for deleted members. New joins wait as invalid;
unrelated components activate. At clean boot only directed dependents of invalid
targets fail. A Guardian.Rules.Server-only restart preserves published bindings and counts;
a Store/node restart loses counts. Very rapid edits with many dependents can fill
the compiled-module pool: a saved file then waits for module reclamation and polling.

A later SET or storage failure can leave earlier TRACK increments; there is no
rollback. Unkeyed client resubmissions count twice. A completed matching
idempotency-key retry on the same node skips rules for ten seconds but returns only
a receipt, without counter/decision fields. Receipt protection is node-local even
though counters have cluster owners; eviction, overload, restart or another node
can bypass it. See [retrying a batch](../reference/api.md#retrying-a-batch).

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
