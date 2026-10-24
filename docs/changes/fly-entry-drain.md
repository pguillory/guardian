# fly-entry-drain: keep the tunnel connector up only while Guardian serves

## Problem

With `TUNNEL_TOKEN` set, `bin/fly-start` started the cloudflared connector at once and
then `exec`ed Guardian. Cloudflare sends a tunnel request to one of the tunnel's
connectors, not to a healthy origin, so the connector forwarded requests to a Guardian
that wasn't serving:

1. At boot, before Guardian listens. Its listener opens only after every segment has
   loaded, which takes longer as data grows.
2. At shutdown, Fly's SIGTERM went to Guardian alone. Guardian closes its listener
   first and then persists for up to about 110 seconds, while the connector stayed up.

Requests in those windows failed with an origin error instead of going to another
connector. With one machine that is part of the restart's downtime anyway; with
several machines, each running a connector for the same tunnel, it fails the
restarting machine's share of tunnel traffic while another machine could take it.

## Behavior after the change

1. Without a connector (no token, or the new `GUARDIAN_TUNNEL=off`), the script
   `exec`s `guardian start`, as before. `GUARDIAN_TUNNEL=off` keeps one machine out of
   tunnel traffic even though the token is an app-wide secret.
2. With a connector, the script starts Guardian in the background and starts the
   connector only once a socket listens on Guardian's port (`GUARDIAN_PORT`, default
   8080), read from `/proc/net/tcp` and `tcp6` because the image has no HTTP client.
3. On SIGTERM or SIGINT it stops the connector first. cloudflared drains in-flight
   requests for up to `--grace-period 10s`; one still running after 20 seconds is
   killed, so a hung connector can't hold up Guardian's shutdown. Then Guardian gets
   SIGTERM and the script exits with Guardian's status.
4. If Guardian exits on its own, the connector is stopped and the script exits with
   Guardian's status, so the machine restarts. A connector that exits is started again
   after 5 seconds, as before; a stop during that pause starts no new one.
5. The token is never in Guardian's environment, in any mode. The script's own shell
   and the connector loop hold it, as cloudflared does.
6. `fly.toml`'s `kill_timeout` goes from 120 to 150 seconds: the connector's drain (10
   seconds, 20 at worst) plus Guardian's roughly 110-second stop, with margin.

A request longer than the drain can still be cut off, and a crash skips the drain.
Whether a caller retries a failed request is the caller's choice.

## Product spec impact

`docs/product/spec.md` section 4.3 item 3: the Fly configuration allows 150 seconds
(was 120). No other user-visible behavior changes.

## Validation

`test/deployment_test.exs` runs the script against fake Guardian and cloudflared
binaries and a fake `/proc/net` directory: connector only after the listener (decoy
sockets don't count), drain before Guardian's SIGTERM, Guardian's exit status passed
on, the token kept from Guardian, `GUARDIAN_TUNNEL=off`, the `exec` path, the IPv4
table and a non-default port, SIGINT, Guardian exiting before it listens or on its
own, SIGTERM before the listener, a connector restart after it exits, SIGTERM during
the restart pause, and a connector that ignores SIGTERM being killed. The suite passes with both macOS `sh` and `dash` (the image's `/bin/sh`). The
`/proc/net/tcp` format and the listener on port 8080 were checked read-only on a
running machine. The drain itself, against Cloudflare, is to be checked on a deploy
with more than one machine.
