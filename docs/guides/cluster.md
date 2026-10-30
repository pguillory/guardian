# Running a cluster on any machines

Each node keeps the events it received, and every query fans out to all connected
nodes. Nodes find each other through DNS. ([Fly.io](fly.md) is a preset of this setup
that needs less configuration.)

## Configuration

Give every node:

1. `GUARDIAN_NODE_HOST`: its own IP address as the other nodes see it. With DNS
   discovery it must be an IP literal written the way Erlang writes it (`10.0.0.5`,
   `fd00::5`, not an expanded or uppercase IPv6 form), and not loopback. A node that
   breaks this refuses to start rather than silently never joining. An IPv6 address
   switches distribution to IPv6.
2. `DNS_CLUSTER_QUERY`: one DNS name that resolves to every node's IP (A records for
   IPv4, AAAA for IPv6). A Kubernetes headless service works, and so does a Docker
   network alias shared by every node. A load-balancer VIP doesn't: the name must
   return each node's own address.
3. `RELEASE_COOKIE`: the same long random secret on every node, in printable ASCII
   (`openssl rand -base64 48`).
4. Its own volume. Segment IDs are per node, and nodes never share storage.
5. If you use rules, the same S3-compatible rule bucket: rule writes to a local
   folder are refused while nodes are connected ([Rule storage](rules.md)).

The machines must reach each other on epmd (4369) and the distribution port. Pin that
port with `GUARDIAN_DIST_PORT`.

Counters use one owner per definition and typed group, chosen from connected nodes
per event; all buckets for that group share the owner. This is ephemeral state:
joins, leaves, rolling deploys, different membership views, partitions and restarts
can lose or split counts. There is no migration or replication. Slow/unavailable
owners supply defaults and ingestion continues. Keep node clocks synchronized for
arrival-time windows, and configure GUARDIAN_COUNTER_MEMORY_MB on each node.

Upgrade every node before adding TRACK/LOOKUP files to a shared rule bucket. Older
nodes that cannot load the syntax fail affected tables' events (or, on older
builds, keep previous plans), so a mixed-version rollout does not give consistent
counter rules.
See [counter edits and retries](rules.md#editing-and-retrying-counters).

The transition from unprefixed modules to `Guardian.*` requires a full release
restart on every node. During a rolling deploy, old and new nodes cannot reliably
exchange module-bearing RPCs or terms: distributed queries can fail and unavailable
counter peer calls supply defaults. Finish upgrading every node before relying on
distributed operations. Stored segments and rule files need no migration.

The [counter client split](../changes/counter-client.md) also renames a peer RPC
module. Mixed-version rolling deploys across that change are unsupported: counter
peer calls fail open with owner cooldown until every node runs the same build.

## Network security

Keep epmd and the distribution port on a private network. Anyone who can reach them
and knows the cookie can run code on every node. Distribution traffic isn't encrypted,
so events cross that network in the clear. Don't reuse a cookie and DNS name across
environments: nodes that find each other join one cluster, and every query then reads
both environments' data.

## Docker Compose example

[`examples/docker-compose.yml`](../../examples/docker-compose.yml) shows a three-node
cluster on one Docker host: a user-defined network with fixed addresses, a shared
network alias as `DNS_CLUSTER_QUERY`, and one volume per node. It hasn't been run as
part of this repository's checks. Treat it as a starting point.

## A standalone long-named node

A node with `GUARDIAN_NODE_HOST` but no `DNS_CLUSTER_QUERY` is a standalone,
long-named node: it discovers nothing on its own, but it listens for distribution on
all interfaces, so it needs the cookie and the same firewalling as a cluster member.

See also the [configuration reference](../reference/configuration.md) and the
cluster-related entries in [known limitations](../reference/limitations.md).
