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
3. `RELEASE_COOKIE`: the same long random secret on every node
   (`openssl rand -base64 48`).
4. Its own volume. Segment IDs are per node, and nodes never share storage.

The machines must reach each other on epmd (4369) and the distribution port. Pin that
port with `GUARDIAN_DIST_PORT`.

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
