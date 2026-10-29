# fly-commands-guide: deploy on Fly with commands, not a fly.toml template

Superseded by [plain-setup](plain-setup.md): `fly launch` writes `fly.toml`, the
reader adds only the stop settings by hand, and the keys are set with `fly secrets set`.

## Problem

The repository carried `fly.example.toml` ([fly-example-config](fly-example-config.md)),
a template every deployment copied and edited by hand. The Fly guide also generated the
API keys inside `fly secrets set`, so a reader never learned their own keys.

## Change

1. `fly.example.toml` is gone. The Fly guide's first deploy builds `fly.toml` with
   commands, checked against flyctl v0.4.111 (its `--help` and source):
   `fly launch --no-deploy --no-github-workflow` with `--name`, `--region`, `--ha=false`,
   `--auto-stop off`, `--vm-size`, `--vm-memory` and `--volume
   guardian_data:/data:initial_size=10gb`, then
   `fly volumes create ... --size 10 --snapshot-retention 14`.
2. The settings flyctl has no command for are one marked addition, applied by two
   commands the guide labels one-time: `kill_signal`/`kill_timeout` prepended (TOML
   top-level keys must precede the first table), and `[deploy]` (rolling,
   `max_unavailable = 1`, and `wait_timeout = "15m"` so that every deploy, rollbacks
   included, waits for a slow boot), `[http_service.concurrency]`, `[[http_service.checks]]`
   and `[[restart]]` appended. The guide says why each exists.
3. The `[env]` setting of `GUARDIAN_DATA_DIR` is dropped: the image already sets it.
4. The keys are generated into exported shell variables, saved to a new file only the
   user can read in their home directory, and then set as secrets through
   `fly secrets import` on standard input, so they stay out of process lists.
5. `fly launch` gets `--no-github-workflow`: in a clone of a GitHub repository it
   would otherwise write a GitHub Actions deploy workflow into the checkout and, with
   the `gh` CLI installed, store a long-lived Fly deploy token as a repository secret
   (flyctl `scanner/github.go`, `launch_frameworks.go` `setupGitHubActions`).
6. Scaling creates the new machine's volume first, so it gets the same snapshot
   retention, and memory changes go through `[[vm]]` in `fly.toml`, since a deploy
   resets what `fly scale memory` set.
7. References to the template in AGENTS.md, the README, system.md, security.md,
   limitations.md, `bin/fly-start`, `.gitignore` and `.dockerignore` now point to the
   guide. `test/guardian/deployment_test.exs` checks the guide instead: its marked
   addition keeps `kill_timeout = 150` with SIGTERM, one-at-a-time deploys and the
   always-restart policy; `fly launch` keeps `--no-github-workflow`; neither sets an
   environment variable; and the Dockerfile sets `GUARDIAN_DATA_DIR=/data`.

The maintainer's own configuration still lives outside the repository.

## Product spec impact

`docs/product/spec.md` section 9, item 7 (Backups), whose "repository's configuration"
no longer exists:

- Before: "On Fly.io, the repository's configuration has Fly snapshot each volume
  daily and keep snapshots 14 days; elsewhere, backups are the operator's to arrange."
- After: "On Fly.io, volumes created as in the Fly guide are snapshotted daily, with
  snapshots kept 14 days; elsewhere, backups are the operator's to arrange."

`docs/product/overview.md`: none.

## Validation

No Fly app, volume or secret was created. A `fly.toml` reconstructed from flyctl's
launch code for these flags, with the addition applied by the guide's commands, parses
as TOML with each setting in its table and passes `fly config validate --strict`.
