# Rule storage

Rules are files named `<table>/<name>.gsql` (the language is in the
[product spec](../product/spec.md#51-rules)). Guardian reads them from one store: a
local folder, or an S3-compatible bucket such as Cloudflare R2. It loads every rule at
startup, after each write through the MCP rule tools, and once a minute, and never
reads the store while ingesting. If the store is misconfigured or unreachable at
startup (after about a minute of retries), Guardian refuses to start rather than run
without its rules.

## A local folder (the default)

With no rule settings, rules live in `<GUARDIAN_DATA_DIR>/rules`; `GUARDIAN_RULES_DIR`
moves them. Files edited there by hand are picked up within a minute and checked like
any write. If a table's rules fail the check, a running node keeps that table's last
good rules and logs the errors; a node starting up rejects that table's events until
the rules are fixed. Any `.gsql` file in a table's folder counts, so a stray or
misnamed one (`logins/README.gsql`) fails that table.

A folder suits one node only. A node that is connected to others refuses rule writes
to a local folder, since each node would have its own copy.

## An S3-compatible bucket

A cluster needs a bucket, so that every node reads the same rules. Set all four of:

| Variable | Meaning |
| --- | --- |
| `GUARDIAN_RULES_S3_BUCKET` | The bucket name. |
| `GUARDIAN_RULES_S3_ENDPOINT` | The S3 endpoint, `https://<host>` with no path (for R2, `https://<account id>.r2.cloudflarestorage.com`). |
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
