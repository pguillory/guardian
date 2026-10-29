# Deploying on Fly.io

Fly is Guardian's best-supported deployment, and a preset of
[the general cluster setup](cluster.md). On a Fly machine the node host defaults to its
private IPv6 address and `DNS_CLUSTER_QUERY` to `<app>.internal`, so a cluster needs
no configuration beyond the cookie. The `Dockerfile` builds the release (including
the column and mmap NIFs), and the commands below run it with:

- a volume at `/data`
- HTTPS at Fly's edge, forwarding to port 8080
- an unauthenticated `GET /health` check
- machines that never auto-stop and always restart

## First deploy

Everything below is a `fly` command, run from your checkout of this repository, except
one addition to the `fly.toml` that `fly launch` writes, for the few settings flyctl has
no command for. Pick an app name (it must be unique across Fly, and becomes
`<app-name>.fly.dev`) and a region (`fly platform regions` lists them, for example
`sjc`).

### 1. Create the app

```sh
fly auth login

fly launch --no-deploy --yes --no-github-workflow \
  --name <app-name> --region <region> --ha=false --auto-stop off \
  --vm-size shared-cpu-1x --vm-memory 1024 \
  --volume guardian_data:/data:initial_size=10gb
```

This creates the app (add `--org <org>` for an organization other than your personal
one) and writes `fly.toml` in the checkout, which git ignores. `--no-github-workflow`
matters: in a clone of a GitHub repository, `fly launch` otherwise writes a GitHub
Actions deploy workflow into the checkout and, when the `gh` CLI is installed, stores a
long-lived Fly deploy token as a secret of that repository. `fly launch` reads the
`Dockerfile` (port 8080) and records what the flags set: machines that never auto-stop
(a stopped machine's events would vanish from queries), one machine with 1 GB of
memory, and the volume `guardian_data` mounted at `/data`. Raise `--vm-memory` for
bigger datasets: loaded segments are memory-mapped.

### 2. Create the volume

```sh
fly volumes create guardian_data --app <app-name> --region <region> \
  --size 10 --snapshot-retention 14 --yes
```

The first deploy attaches this volume. Creating it yourself sets its daily snapshots to
be kept 14 days instead of Fly's default 5.

### 3. Add the settings flyctl has no command for

flyctl has no command or flag that writes these to `fly.toml`, so the two commands below
add them. Run them once, on the `fly.toml` that `fly launch` just wrote: running them
again would repeat the settings and break the file.

<!-- fly-toml-additions -->
```sh
printf 'kill_signal = "SIGTERM"\nkill_timeout = 150\n\n' | cat - fly.toml > fly.toml.new &&
  mv fly.toml.new fly.toml

cat >> fly.toml <<'EOF'

[deploy]
  strategy = "rolling"
  max_unavailable = 1
  wait_timeout = "15m"

[http_service.concurrency]
  type = "requests"
  soft_limit = 200
  hard_limit = 250

[[http_service.checks]]
  method = "GET"
  path = "/health"
  interval = "15s"
  timeout = "5s"
  grace_period = "1m"

[[restart]]
  policy = "always"
EOF
```

The first command puts two lines at the top of the file, where TOML requires settings
that belong to no section:

```toml
kill_signal = "SIGTERM"
kill_timeout = 150
```

Fly stops a machine with SIGINT by default, which isn't a graceful shutdown for
Guardian. On SIGTERM it saves its in-memory segments, within a budget of about 110
seconds, after the tunnel connector (if any) has drained for up to 10 seconds, 20 at
worst (`bin/fly-start`); `kill_timeout` must stay above both.

The second appends the rest:

1. `[deploy]`: replace machines one at a time, since each volume attaches to one
   machine, and wait up to 15 minutes for each new machine to pass its health check
   (Fly's default is 5).
2. `[http_service.concurrency]`: up to 200 requests per machine before Fly's edge
   prefers another machine, and 250 at most.
3. `[[http_service.checks]]`: the health check. A machine answers it only after
   loading every segment on its volume. Fly caps the grace period at 1 minute, so a
   slow boot is covered by the deploy's `wait_timeout` above.
4. `[[restart]]`: restart a machine whenever Guardian exits.

### 4. Generate and save the keys, then set them

Run this once. Run again, it stops at the existing key file and sets nothing on Fly,
but your shell then holds new keys: reload the saved ones as described below.

```sh
export GUARDIAN_ADMIN_API_KEY="$(openssl rand -hex 32)"
export GUARDIAN_INGEST_API_KEY="$(openssl rand -hex 32)"

(umask 077; set -o noclobber
 printf 'GUARDIAN_ADMIN_API_KEY=%s\nGUARDIAN_INGEST_API_KEY=%s\n' \
   "$GUARDIAN_ADMIN_API_KEY" "$GUARDIAN_INGEST_API_KEY" > ~/guardian-<app-name>.env) &&
printf 'GUARDIAN_ADMIN_API_KEY=%s\nGUARDIAN_INGEST_API_KEY=%s\nRELEASE_COOKIE=%s\n' \
  "$GUARDIAN_ADMIN_API_KEY" "$GUARDIAN_INGEST_API_KEY" \
  "$(openssl rand -base64 48 | tr -d '\n/+=')" |
  fly secrets import --stage --app <app-name>
```

Fly never shows a secret's value again (`fly secrets list` shows only digests), so the
parenthesized command first saves both keys to a new file only you can read, in your
home directory rather than the checkout so it can't be committed. It refuses to
overwrite an existing file, and then nothing is set. Move the keys into your password
manager when you can. In a new shell, load them again with
`set -a; . ~/guardian-<app-name>.env; set +a`. The rest passes the secrets to Fly on
standard input, so they never appear in a process list.

The admin key is for you and your agents over MCP; the ingest key is for the
applications that send events, and can do nothing else. A deployment that still
sets the deprecated `GUARDIAN_API_KEY` keeps working with it. Give your applications
only the ingest key. `RELEASE_COOKIE` lets machines join one cluster; nothing outside
Fly needs it.

### 5. Deploy

```sh
fly deploy --ha=false --build-arg GIT_COMMIT="$(git rev-parse HEAD)"
```

The first deploy creates one machine on the `guardian_data` volume. Make sure the app
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

### Keeping fly.toml elsewhere

Run every `fly` command from the checkout, so it finds your `fly.toml` and builds the
checkout's `Dockerfile`. To keep your configuration outside the checkout instead (so
every checkout and worktree shares it), move `fly.toml` there and pass it to
`fly deploy` with `-c`, naming the checkout as the working directory,
`fly deploy . -c /path/to/fly.toml ...`, and pass `-a <app-name>` (or the same `-c`)
to the other commands. Don't add a Dockerfile path to its `[build]` section: flyctl
reads that path relative to the configuration's directory, not the checkout. If you
lose your copy, `fly config save -a <app-name> -c <path>` writes the deployed
configuration back, without its comments.

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
`fly releases --image` and run `fly deploy --image <image>`. Releases from before the
admin and ingest keys know only `GUARDIAN_API_KEY`, so rolling back to one refuses
callers that have moved to the new keys. A machine answers its health check only after
loading every segment on its volume. Fly caps the check's grace period at 1 minute, so
what covers a slow boot is `fly deploy`, rollbacks included, which waits up to
`[deploy] wait_timeout` (15 minutes) for the check to pass; raise it if boots get
slower.

## Operating it

The remote console is `fly ssh console --pty -C "/app/bin/guardian remote"`. Inside it,
`Node.list()` shows the connected peers. Rotate a key with, for example,
`fly secrets set GUARDIAN_INGEST_API_KEY=...`, which restarts the machine; each key
rotates independently of the others.

## Scaling

To scale, create a volume for the new machine first, the same way as for the first
one, then add the machine:

```sh
fly volumes create guardian_data --app <app-name> --region <region> \
  --size 10 --snapshot-retention 14 --yes
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

To change a machine's memory, edit `memory` in the `[[vm]]` section of your `fly.toml`
(for example `memory = '2gb'`) and deploy. `fly scale memory` changes the running
machines, but the next `fly deploy` sets them back to what `fly.toml` says.

## Optional: Cloudflare Tunnel

When the `TUNNEL_TOKEN` secret is set, the image's entry point (`bin/fly-start`)
starts a cloudflared connector beside Guardian. The connector opens an outbound
Cloudflare Tunnel, so Cloudflare Workers can reach Guardian through a Workers VPC
binding instead of the public edge. The same API keys apply. Without the token, the
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
from your `fly.toml` and drops the setting, so exclude it (`--exclude-machines <id>`) for as
long as it should stay out.

See also the [configuration reference](../reference/configuration.md) and
[known limitations](../reference/limitations.md).
