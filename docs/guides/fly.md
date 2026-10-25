# Deploying on Fly.io

Fly is Guardian's best-supported deployment, and a preset of
[the general cluster setup](cluster.md). On a Fly machine the node host defaults to its
private IPv6 address and `DNS_CLUSTER_QUERY` to `<app>.internal`, so a cluster needs
no configuration beyond the cookie. The `Dockerfile` builds the release (including
the column and mmap NIFs), and `fly.toml` runs
it with:

- a volume at `/data`
- HTTPS at Fly's edge, forwarding to port 8080
- an unauthenticated `GET /health` check
- machines that never auto-stop and always restart

## First deploy

The `fly.toml` in this repository is the maintainer's own deployment. Before your
first deploy:

1. Set `app` to your app's name and `primary_region` to your region (for example
   `sjc`).
2. Delete the block marked "this deployment's overrides", so your deploy gets
   Guardian's defaults.
3. Adjust `[[vm]]` or the volume's `initial_size` (10 GB) if needed.

```sh
fly auth login
fly apps create <app-name>

fly secrets set --stage \
  GUARDIAN_API_KEY="$(openssl rand -hex 32)" \
  RELEASE_COOKIE="$(openssl rand -base64 48 | tr -d '\n/+=')"

fly deploy --ha=false --wait-timeout 15m \
  --build-arg GIT_COMMIT="$(git rev-parse HEAD)"
```

The first deploy creates one machine and its `guardian_data` volume. Make sure the app
has public addresses (a first `fly deploy` normally allocates them), then check it:

```sh
fly ips list
fly ips allocate-v6          # only if no v6 address is listed
fly ips allocate-v4 --shared # only if no v4 address is listed
fly status
curl https://<app-name>.fly.dev/health
fly logs
```

On Fly, a machine refuses to start unless `/data` is a mounted volume, so it can't
silently keep events on its disposable root filesystem. You can attach a custom domain
with `fly certs add <domain>`.

## Later deploys and rollbacks

When upgrading from unprefixed modules to `Guardian.*`, restart the full release on
every machine. During the rolling deploy, distributed queries can fail and counter
peer calls can supply defaults until every machine runs the new build. Stored
segments and rule files need no migration; see the
[namespace compatibility audit](../changes/guardian-namespace.md).

The [counter client split](../changes/counter-client.md) also renames a peer RPC
module. Upgrade and restart every machine before relying on distributed counters;
mixed-version peer calls fail open with owner cooldown.

Later deploys run the same `fly deploy` command. With one machine, each deploy briefly
stops ingestion, because the volume attaches to only one machine: the old release stops
before the new one starts, so producers must retry. A new release that fails its health
check stops the deploy but doesn't roll back. To roll back, find the previous image with
`fly releases --image` and run `fly deploy --image <image>`. The health check allows 10
minutes for segments to load; keep `--wait-timeout` above that, and raise both if boots
get slower.

## Operating it

The remote console is `fly ssh console --pty -C "/app/bin/guardian remote"`. Inside it,
`Node.list()` shows the connected peers. Rotate the key with
`fly secrets set GUARDIAN_API_KEY=...`, which restarts the machine.

## Scaling

To scale, run `fly scale count 2`. That creates a machine and a new volume, and the
machine joins the cluster within seconds. With more than one machine:

- Deploys replace machines one at a time, so ingestion continues on the others.
- Queries miss a machine's data until it has loaded its segments.
- A query running while a machine shuts down can fail with a node error. Retry it.
- Rules need an S3-compatible bucket: rule writes to the default local folder are
  refused while machines are connected ([Rule storage](rules.md)).

Scaling down destroys a machine but leaves its volume unattached. That machine's
events drop out of queries until a machine uses that volume again.

## Optional: Cloudflare Tunnel

When the `TUNNEL_TOKEN` secret is set, the image's entry point (`bin/fly-start`)
starts a cloudflared connector beside Guardian. The connector opens an outbound
Cloudflare Tunnel, so Cloudflare Workers can reach Guardian through a Workers VPC
binding instead of the public edge. The same API key applies. Without the token, the
entry point is exactly `guardian start`. Import the token from a protected source
(`fly secrets import --stage`) rather than typing it on a command line.

Every machine of the app gets the secret, so each runs its own connector, and
Cloudflare sends each request to one of them. The entry point keeps a machine's
connector up only while its Guardian serves: the connector starts once Guardian
listens (after loading its segments), and on shutdown it stops before Guardian does,
draining in-flight requests for up to 10 seconds (it is killed if it takes longer
than 20), so new requests can go to another machine's connector in the meantime.
`kill_timeout` (150 s) covers the drain and Guardian's own shutdown.

To keep one machine out of tunnel traffic, set `GUARDIAN_TUNNEL=off` in that
machine's own environment (`fly machine update <id> --env GUARDIAN_TUNNEL=off`, which
restarts it). A later `fly deploy` that includes the machine rebuilds its environment
from `fly.toml` and drops the setting, so exclude it (`--exclude-machines <id>`) for as
long as it should stay out.

See also the [configuration reference](../reference/configuration.md) and
[known limitations](../reference/limitations.md).
