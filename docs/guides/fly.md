# Deploying on Fly.io

Fly is Guardian's best-supported deployment, and a preset of
[the general cluster setup](cluster.md). Fly puts HTTPS in front of Guardian, and on a
Fly machine Guardian finds its peers by itself, so a cluster needs no configuration
beyond a shared cookie.

You'll need the [`fly` command](https://fly.io/docs/flyctl/install/) and a checkout of
this repository. Run every command below from the checkout.

## First deploy

Pick an app name and a region. The name must be unique across Fly and becomes your
address, `https://<app>.fly.dev`. `fly platform regions` lists the regions, for
example `sjc`.

### 1. Sign in

```sh
fly auth login
```

### 2. Create the app

```sh
fly launch --name <app> --region <region> --auto-stop off \
  --volume guardian_data:/data --no-github-workflow --no-deploy
```

`fly launch` creates the app and writes its configuration, `fly.toml`, from the
`Dockerfile` (git ignores `fly.toml`). It shows what it will create and asks whether
to tweak the settings; answer no. The flags:

- `--auto-stop off` keeps the machine running. A stopped machine's events would
  vanish from queries.
- `--volume guardian_data:/data` keeps events on a volume, which survives deploys.
- `--no-github-workflow` stops `fly launch` from adding a GitHub Actions workflow to
  the checkout and storing a Fly deploy token in your GitHub repository.
- `--no-deploy`, because the next steps come first.

### 3. Create the volume

```sh
fly volumes create guardian_data --region <region> --size 10 --snapshot-retention 14
```

This makes a 10 GB volume, snapshotted daily, with snapshots kept 14 days instead of
Fly's default 5. Fly warns that a single volume risks downtime; answer yes.

### 4. Give Guardian time to shut down

Open `fly.toml` and add these two lines below the `primary_region` line, above the
first `[section]`:

<!-- fly-toml-settings -->
```toml
kill_signal = "SIGTERM"
kill_timeout = 150
```

This is the one setting `fly launch` can't make for you. By default Fly stops a machine
with SIGINT and kills it 5 seconds later. Guardian keeps up to an hour of recent events
in memory and saves them before it stops only when sent SIGTERM; saving can take about
two minutes. Without these lines, every deploy or restart can lose that hour.

### 5. Make your keys

Run this twice:

```sh
openssl rand -hex 32
```

The first output is your admin key, the second your ingest key. Save both in your
password manager now: Fly won't show them to you again. Then give them to Guardian:

```sh
fly secrets set GUARDIAN_ADMIN_API_KEY=<admin-key> GUARDIAN_INGEST_API_KEY=<ingest-key> \
  RELEASE_COOKIE=$(openssl rand -hex 32)
```

The admin key is for you and your agents. The ingest key is for your applications,
and can only send events. The cookie lets your machines form a cluster; nobody else
needs it.

### 6. Deploy

Before deploying a checkout you have changed, here and on every later deploy, run
`mix test --include cluster`: the default suite and the pre-commit hook leave out the
peer-VM tests.

```sh
fly deploy
```

The first deploy builds the image, creates one machine on the volume, and gives the
app its public addresses. Check that it answers:

```sh
curl https://<app>.fly.dev/health
```

If the curl can't connect, `fly ips list` shows the app's addresses, and
`fly ips allocate` adds them. `fly logs` shows what the machine is doing.

You now have the app name and both keys. On Fly, a machine refuses to start unless
`/data` is a mounted volume, so it can't silently keep events on its disposable disk.
You can attach a custom domain with `fly certs add <domain>`.

## Later deploys and rollbacks

When upgrading from unprefixed modules to `Guardian.*`, restart the full release on
every machine. During the rolling deploy, distributed queries can fail and counter
peer calls can supply defaults until every machine runs the new build. Stored
segments and rule files need no migration; see the
[namespace compatibility audit](../changes/guardian-namespace.md).

The [counter client split](../changes/counter-client.md) also renames a peer RPC
module. Upgrade and restart every machine before relying on distributed counters;
mixed-version peer calls fail open with owner cooldown.

Later deploys run the same `fly deploy`. With one machine, each deploy briefly stops
ingestion, because the volume attaches to only one machine: the old release stops
before the new one starts, so producers must retry. A deploy that fails stops without
rolling back. To roll back, find the previous image with `fly releases --image` and
run `fly deploy --image <image>`. Releases from before the admin and ingest keys know
only `GUARDIAN_API_KEY`, which current releases no longer read, so rolling back to one
refuses every caller until that key is set again and callers use it.

## Operating it

The remote console is `fly ssh console --pty -C "/app/bin/guardian remote"`. Inside it,
`Node.list()` shows the connected peers. Rotate a key with, for example,
`fly secrets set GUARDIAN_INGEST_API_KEY=...`, which restarts the machine; each key
rotates independently of the other.

## Keeping fly.toml elsewhere

`fly` commands find `fly.toml` in the current directory. To keep your configuration
outside the checkout instead (so every checkout and worktree shares it), move
`fly.toml` there and deploy with `fly deploy . -c /path/to/fly.toml`, which builds the
checkout's `Dockerfile`; pass `-a <app>` (or the same `-c`) to the other commands.
Don't add a Dockerfile path to its `[build]` section: flyctl reads that path relative
to the configuration's directory, not the checkout. If you lose your copy,
`fly config save -a <app> -c <path>` writes the deployed configuration back, without
its comments.

## Scaling

Before adding a second machine, make deploys wait for each machine to be ready. A
machine answers `GET /health` only once it has loaded every segment on its volume,
which can take minutes. Without a health check, a rolling deploy moves on as soon as a
machine starts, so several machines can be loading at once, and ingestion and queries
miss all of them. In `fly.toml`, add a health check to the `[http_service]` section
and a `[deploy]` section:

```toml
[[http_service.checks]]
  path = "/health"
  interval = "15s"
  timeout = "5s"
  grace_period = "1m"

[deploy]
  strategy = "rolling"
  max_unavailable = 1
  wait_timeout = "15m"
```

`max_unavailable = 1` replaces one machine at a time (Fly's default is a third of
them, which is more than one from four machines on). Fly caps the check's grace period
at 1 minute, so `wait_timeout` is what covers a slow boot: `fly deploy`, rollbacks
included, waits that long for each machine to pass its check. Raise it if boots get
slower. A new release that fails its check stops the deploy without rolling back.
A machine whose rule store is unreachable waits for it at boot, so it fails its check
until the store answers and a rolling deploy stops there, leaving the other machines
running.

Then create a volume for the new machine, the same way as for the first, and add the
machine:

```sh
fly volumes create guardian_data --region <region> --size 10 --snapshot-retention 14
fly scale count 2
```

`fly scale count` gives the new machine an unattached `guardian_data` volume, and
creates one only when none is left (with Fly's default 5-day snapshot retention). The
machine joins the cluster within seconds. With more than one machine:

- Deploys replace machines one at a time, so ingestion continues on the others.
- Queries miss a machine's data until it has loaded its segments.
- A query running while a machine shuts down can fail with a node error. Retry it.
- Rules need an S3-compatible bucket: rule writes to the default local folder are
  refused while machines are connected ([Rule storage](rules.md)).

Scaling down destroys a machine but leaves its volume unattached. That machine's
events drop out of queries until a machine uses that volume again.

Machines start with 1 GB of memory. Loaded segments are memory-mapped, so bigger
datasets want more. To change it, edit `memory` in the `[[vm]]` section of your
`fly.toml` (for example `memory = '2gb'`) and deploy. `fly scale memory` changes the
running machines, but the next `fly deploy` sets them back to what `fly.toml` says.

## Optional: Cloudflare Tunnel

When the `TUNNEL_TOKEN` secret is set, the image's entry point (`bin/fly-start`)
starts a cloudflared connector beside Guardian. The connector opens an outbound
Cloudflare Tunnel, so Cloudflare Workers can reach Guardian through a Workers VPC
binding instead of the public edge. The same API keys apply. Without the token, the
entry point is exactly `guardian start`. Unlike the API keys, which you make
yourself, the token comes from Cloudflare and grants its tunnel, so import it from a
protected source (`fly secrets import --stage`) rather than typing it on a command line.

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
from your `fly.toml` and drops the setting, so exclude it (`--exclude-machines <id>`) for as
long as it should stay out.

See also the [configuration reference](../reference/configuration.md) and
[known limitations](../reference/limitations.md).
