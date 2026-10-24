# Configuration

Everything is set through environment variables. Only `GUARDIAN_API_KEY` is required.

| Variable | Default | Meaning |
| --- | --- | --- |
| `GUARDIAN_API_KEY` | (required) | The one API key. At least 32 bytes; generate it with `openssl rand -hex 32`. Rotating it takes effect at restart and doesn't affect stored data. |
| `GUARDIAN_DATA_DIR` | `/data` in the image, `/root/data` for a bare release | Where segments are stored. Startup refuses a directory it can't write, so set it when running a bare release as a non-root user. On Fly it must be the mounted volume. |
| `GUARDIAN_PORT` | `8080` | The HTTP port. |
| `GUARDIAN_ALLOW_QUERY_API_KEY` | `false` | `true` also accepts the key as an `api_key` query parameter. URLs end up in logs and history more readily than headers, so leave it off unless a client can't send the `x-api-key` header. |
| `GUARDIAN_QUERY_MAX_HEAP_MB` | `256` | The heap limit for each process a query runs in. `0` turns it off. See [Known limitations](limitations.md). |
| `GUARDIAN_MUTABLE_SEGMENT_MAX_AGE_MS` | `3600000` | How long an in-memory segment collects events before it's handed off to disk. |
| `GUARDIAN_NODE_HOST` | (unset; `FLY_PRIVATE_IP` on Fly) | The address other nodes reach this node at. Setting it makes the node a cluster member named `guardian@<address>`. |
| `DNS_CLUSTER_QUERY` | (unset; `<app>.internal` on Fly) | A DNS name resolving to every node's IP. Nodes poll it every 5 s and connect to the peers it returns. |
| `RELEASE_COOKIE` | (required when clustered) | The Erlang distribution secret, shared by every node. It grants code execution on all of them. |
| `GUARDIAN_DIST_PORT` | (unset: a random port) | Pins the server's Erlang distribution port, so a firewall needs only that port and epmd's 4369. |
| `TUNNEL_TOKEN` | (unset) | Optional: starts a Cloudflare Tunnel connector beside Guardian (see [Fly.io: optional Cloudflare Tunnel](../guides/fly.md#optional-cloudflare-tunnel)). |
| `GUARDIAN_TUNNEL` | (unset: on) | `off` keeps the tunnel connector from starting on this machine even when `TUNNEL_TOKEN` is set. |

How these combine into a deployment: [single node](../guides/single-node.md),
[a cluster on any machines](../guides/cluster.md), and [Fly.io](../guides/fly.md).
