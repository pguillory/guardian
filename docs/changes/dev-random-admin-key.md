# dev-random-admin-key: no key needed to run locally

## Problem

Starting Guardian locally (`iex -S mix`, `mix run --no-halt`, `make console`) failed
with "GUARDIAN_ADMIN_API_KEY must be set" until the developer generated and exported
a key, a step that protects nothing on a laptop.

## Change

1. A Mix run with `MIX_ENV=dev` and no `GUARDIAN_ADMIN_API_KEY` generates a random
   32-byte admin key (64 hex characters) for that run and prints it to stderr:
   "GUARDIAN_ADMIN_API_KEY is not set; this dev run uses a generated admin key: ...".
   Each run gets a new key; a developer who wants a stable one sets the variable.
2. Everything else about the keys is unchanged, in dev too: a set but empty or short
   key is refused, the removed `GUARDIAN_API_KEY` without the admin key gets its
   error, and the ingest key is optional and never generated.
3. A release still refuses to start without the admin key, and nothing an operator
   sets at runtime changes that:
   - `config/runtime.exs` takes the dev path only when `config_env()` is `:dev`. In a
     release that is the `MIX_ENV` it was built with, recorded in the release at
     build time; `MIX_ENV` at runtime has no effect.
   - `mix.exs` refuses to build a release outside `MIX_ENV=prod` (a release step that
     raises), so no release is built with `:dev`. The Dockerfile already builds with
     `MIX_ENV=prod`.
   - The branch also requires Mix to be loadable, and a release does not include Mix.
   Defeating these would take code or files already planted on the host, which grant
   more than this path does.
4. Tests keep their fixed keys from `config/config.exs`; `config/runtime.exs` does not
   read the key variables in the test env.

## Tests

`test/guardian/config/runtime_test.exs` reads `config/runtime.exs` with env `:dev`
(generation, printing, a fresh key per run, a set key used silently, invalid keys and
the removed key still refused) and with `:prod` (refusal, as before).
`test/guardian/mix_project_test.exs` checks the release step refuses outside
`MIX_ENV=prod` and that the release uses it.

## Deploy

Nothing to do: production sets the admin key, and a prod release behaves as before.
