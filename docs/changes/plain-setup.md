# plain-setup: a README and Fly guide a newcomer can follow

## Problem

The README's setup repeated the Fly guide's first deploy: a `fly launch` with seven
flags, a `printf` and a heredoc that wrote settings into `fly.toml`, and a secrets step
that chained `umask`, `noclobber` and `printf` into `fly secrets import`. A newcomer
couldn't see what Guardian is past it. The guide carried Fly tuning (edge
concurrency, deploy strategy, health check, restart policy) that a first deployment
doesn't need, and the README's helper was written twice, in Python and JavaScript,
with branching the reader had to follow.

## Change

1. The README's How to run it is three steps with no deploy commands: a link to the
   Fly guide (you come back with an app name, an ingest key and an admin key), one
   curl with the ingest key, and `claude mcp add` with the admin key.
2. The Fly guide's first deploy is `fly auth login`, `fly launch --name <app> --region
   <region> --auto-stop off --volume guardian_data:/data --no-github-workflow
   --no-deploy`, `fly volumes create ... --size 10 --snapshot-retention 14`, a
   two-line hand edit of `fly.toml`, `fly secrets set` and `fly deploy`. `fly launch`
   writes `fly.toml`; no command writes to or appends to it.
3. The hand edit is `kill_signal = "SIGTERM"` and `kill_timeout = 150`, the one setting
   with no flyctl command or flag: `fly launch --signal` and `fly deploy --signal` only
   stop old machines in a bluegreen deploy, and each `fly deploy` rebuilds a machine's
   stop configuration from `fly.toml` (flyctl v0.4.111
   `appconfig/machines.go tomachineSetStopConfig`), so a `fly machine update` wouldn't
   last. Without it, Fly stops a machine with SIGINT and kills it after 5 seconds, and
   Guardian loses the in-memory segments (up to about an hour of events) on every
   deploy or restart.
4. Keys: the reader runs `openssl rand -hex 32` twice, saves the admin and ingest keys
   in a password manager, and passes them to `fly secrets set` with a cookie generated
   inline. The keys pass through the shell's history and, briefly, the local process
   list (the previous guide kept them out of both); the guide accepts that for an
   operator's own machine, where Claude Code keeps the admin key in plain text in its
   configuration anyway (security.md section 7.1).
5. Dropped, each because a default already does the job or it is tuning:
   `--yes`, `--ha=false` (`fly deploy` creates one machine for a group with a volume),
   `--vm-size shared-cpu-1x --vm-memory 1024` (`fly launch`'s default), the volume's
   `initial_size` (the volume is created first), `[http_service.concurrency]` (Fly's
   default: soft limit 20 connections, no hard limit), `[[restart]] policy = "always"`
   (Fly's default, on-failure, restarts a machine whose process exits with an error,
   by default up to 10 times, per Fly's machine restart policy documentation), `--build-arg GIT_COMMIT` (it fed only the startup log line, which now
   says `unknown` on Fly), and, for a single machine, the health check and
   `[deploy]` (`strategy`, `max_unavailable`, `wait_timeout`).
6. Scaling now starts by adding, in plain words, a health check on `GET /health`, and
   a rolling `[deploy]` with `max_unavailable = 1` and `wait_timeout = "15m"`: without them a
   rolling deploy moves on as soon as a machine starts, and from four machines Fly
   replaces a third of them at once.
7. The walkthrough says what each snippet is, uses `SET is_blocked = true WHERE ip =
   '...'`, and presents the counter rule as the agent's replacement rule. The helper
   is `send_event`, in Python with `requests`, with module constants for the full URL
   and headers; it always sends `return_keys` (the server accepts null, `Guardian.Web.Ingest`).
   The JavaScript helper is gone.
8. `test/guardian/deployment_test.exs` checks the guide's marked `fly.toml` settings
   block, `--no-github-workflow` and the absence of Guardian settings. The checks for
   the dropped `[deploy]` and `[[restart]]` settings and for the README's copies of
   the guide's commands are removed: the README has none.
9. AGENTS.md, `docs/architecture/system.md` (10.2 and the passages citing the
   dropped settings), `docs/architecture/security.md` (edge concurrency, the cookie's
   size) and the product spec follow.

## Product spec impact

`docs/product/spec.md` section 4.3:

- Before: "The Fly.io deployment uses it to gate rolling deploys, and any load
  balancer or orchestrator can use it the same way."
  After: "A Fly.io deployment with several machines, set up as the Fly guide's
  Scaling section describes, uses it to gate rolling deploys, and any load balancer
  or orchestrator can use it the same way."

`docs/product/spec.md` section 10:

- Item 7, before: "Single-node deploys stop ingestion briefly; producers must retry.
  Multi-node deploys on Fly roll one machine at a time: ingestion continues on the
  other machines, queries miss the replaced machine's events until it has started, a
  query running as a machine shuts down can fail, and queries spanning old and new
  releases can fail; retry them."
  After: "Single-node deploys stop ingestion briefly; producers must retry.
  Multi-node deploys on Fly, set up as the Fly guide's Scaling section describes,
  roll one machine at a time and wait for each to load its segments: ingestion
  continues on the other machines, queries miss the replaced machine's events until
  it has started, a query running as a machine shuts down can fail, and queries
  spanning old and new releases can fail; retry them."
- Item 8, before: "On Fly, a failed deploy health check stops the deploy without
  rolling back."
  After: "On Fly, a failed deploy stops without rolling back."

`docs/product/overview.md`: none.

## Validation

No Fly app, volume, secret or machine was created. Every flag was checked against
`fly <command> --help` and flyctl v0.4.111's source; Fly's defaults for concurrency,
stop signal and timeout, and restart policy against Fly's documentation.
`claude mcp add --transport http <name> <url> --header ...` matches
`claude mcp add --help`. The README's curl and its Python helper, copied with only the
URL and key replaced, ran against a local Guardian with throwaway keys, as did the
walkthrough's rules.
