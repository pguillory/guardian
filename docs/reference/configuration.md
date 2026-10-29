# Configuration

Everything is set through environment variables. Only a full-access key is required:
`GUARDIAN_ADMIN_API_KEY`, or the deprecated `GUARDIAN_API_KEY`. Each key that is set
must be at least 32 bytes (generate one with `openssl rand -hex 32`), and no two may be
the same; startup refuses otherwise, naming the variable but never its value. Each key
rotates independently: a change takes effect at restart and doesn't affect stored data.

| Variable | Default | Meaning |
| --- | --- | --- |
| `GUARDIAN_ADMIN_API_KEY` | (unset) | The full-access key: MCP (queries, rules, ingestion) and `POST /api/json/send_events`. For the operator and their agents. Required unless `GUARDIAN_API_KEY` is set. |
| `GUARDIAN_INGEST_API_KEY` | (unset) | Optional insert-only key, accepted only by `POST /api/json/send_events`; anywhere else it gets 403. For the applications that produce events. |
| `GUARDIAN_API_KEY` | (unset) | Deprecated. While set, it has full access like `GUARDIAN_ADMIN_API_KEY`, so existing callers keep working until they move to the new keys; a later release removes it. Once insert-only callers use the ingest key, rolling back to a release without it refuses them, since older releases only know `GUARDIAN_API_KEY`. |
| `GUARDIAN_DATA_DIR` | `/data` in the image, `/root/data` for a bare release | Where segments are stored. Startup refuses a directory it can't write, so set it when running a bare release as a non-root user. On Fly it must be the mounted volume. |
| `GUARDIAN_PORT` | `8080` | The HTTP port. |
| `GUARDIAN_QUERY_MAX_HEAP_MB` | `256` | The heap limit for each process a query runs in. `0` turns it off. See [Known limitations](limitations.md). |
| `GUARDIAN_COUNTER_MEMORY_MB` | `64` | Positive integer MiB for the asynchronous resident counter memory target on this node; empty, zero, negative or non-integer values refuse startup. Excludes mailboxes, temporary copies and other VM memory. Housekeeping runs about every second; writes can temporarily overshoot. Expired keys are reclaimed first, then a sampled earliest-expiry cutoff evicts live buckets (possibly all when expiries tie). Restart to change; counts are ephemeral. See [counters](../guides/rules.md#counters-with-track-and-lookup). |
| `GUARDIAN_MUTABLE_SEGMENT_MAX_AGE_MS` | `3600000` | How long an in-memory segment collects events before it's handed off to disk. |
| `GUARDIAN_NODE_HOST` | (unset; `FLY_PRIVATE_IP` on Fly) | The address other nodes reach this node at. Setting it makes the node a cluster member named `guardian@<address>`. |
| `DNS_CLUSTER_QUERY` | (unset; `<app>.internal` on Fly) | A DNS name resolving to every node's IP. Nodes poll it every 5 s and connect to the peers it returns. |
| `RELEASE_COOKIE` | (required when clustered) | The Erlang distribution secret, shared by every node. It grants code execution on all of them. |
| `GUARDIAN_DIST_PORT` | (unset: a random port) | Pins the server's Erlang distribution port, so a firewall needs only that port and epmd's 4369. |
| `GUARDIAN_RULES_DIR` | `<GUARDIAN_DATA_DIR>/rules` | The folder rule files live in, when there's no bucket. It can't be `GUARDIAN_DATA_DIR`, a folder containing it, or inside its `segments` folder. See [Rule storage](../guides/rules.md). |
| `GUARDIAN_RULES_S3_BUCKET`, `GUARDIAN_RULES_S3_ENDPOINT`, `GUARDIAN_RULES_S3_ACCESS_KEY_ID`, `GUARDIAN_RULES_S3_SECRET_ACCESS_KEY` | (unset) | Keep rules in an S3-compatible bucket instead, as a cluster needs. Set all four or none; the secret belongs with your other secrets. See [Rule storage](../guides/rules.md). |
| `GUARDIAN_RULES_S3_REGION`, `GUARDIAN_RULES_S3_PREFIX` | `auto`, none | Optional bucket settings: the signing region, and a key prefix ending in `/` (letters, digits and `. _ ~ / -` only). |
| `TUNNEL_TOKEN` | (unset) | Optional: starts a Cloudflare Tunnel connector beside Guardian (see [Fly.io: optional Cloudflare Tunnel](../guides/fly.md#optional-cloudflare-tunnel)). |
| `GUARDIAN_TUNNEL` | (unset: on) | `off` keeps the tunnel connector from starting on this machine even when `TUNNEL_TOKEN` is set. |

`GUARDIAN_ALLOW_QUERY_API_KEY` no longer exists and is ignored if set: a key is
accepted only in the `x-api-key` header, never in the URL.

How these combine into a deployment: [single node](../guides/single-node.md),
[a cluster on any machines](../guides/cluster.md), and [Fly.io](../guides/fly.md).
