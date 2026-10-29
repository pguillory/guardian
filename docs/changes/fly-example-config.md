# fly-example-config: a template fly.toml; deployments keep their own outside the tree

Superseded by [fly-commands-guide](fly-commands-guide.md): the template is gone, and
the Fly guide builds `fly.toml` with commands.

## Problem

The repository's `fly.toml` was the maintainer's own deployment: his app name, plus a
block of overrides of Guardian's defaults that a test pinned so they would not be
dropped by accident. A public repository should not carry one deployment's
configuration, and anyone deploying had to know which parts to delete first.

## Change

1. `fly.toml` becomes `fly.example.toml`, a template with a placeholder app name and
   no overrides (query-api-key-off and query-heap-fixed removed the two settings it
   overrode). It has no `[build]` section: flyctl resolves `[build] dockerfile`
   against the configuration file's directory, so a copy kept outside the checkout
   would look for the Dockerfile in the wrong place; without it, flyctl builds the
   working directory's `Dockerfile`.
2. `/fly.toml` is gitignored. A deployment copies the template to `fly.toml` in its
   checkout, or keeps it elsewhere and deploys with `fly deploy . -c <path>`.
3. The test that pinned the maintainer's overrides is gone. Tests now check the
   template: its `kill_timeout` still covers the shutdown budget, it has no
   `[build]` section, and it sets no Guardian setting but `GUARDIAN_DATA_DIR`.
4. The README's "Run it" starts by copying the template.
5. The Fly guide describes both ways to hold the configuration, including `-a` or
   `-c` for commands other than `deploy`, and recovering a lost copy with
   `fly config save`.

The maintainer's own configuration now lives outside the repository; deploying it
means passing it with `-c` from the checkout being deployed.

## Product spec impact

None. Deployment documentation only.

## Validation

`test/guardian/deployment_test.exs` checks the template as above. The first deploy
with a configuration outside the checkout is the real check of the `-c` command.
