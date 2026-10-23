# Contributing

Thanks for your interest in Guardian.

## Setup

Install the prerequisites listed in
[docs/guides/development.md](docs/guides/development.md):

- Elixir and Erlang/OTP, at the `ELIXIR_VERSION` and `OTP_VERSION` in the `Dockerfile`
- a C toolchain

Then:

```sh
mix deps.get
bin/install-git-hooks
```

`mix deps.get` fetches the dev dependencies too, and the formatter needs them
(`freedom_formatter` is a dev-only plugin), so run it without `--only`.

## Checks

The pre-commit hook runs the same checks as CI:

```sh
mix format --check-formatted
MIX_ENV=test mix compile --warnings-as-errors
mix test
```

The multi-node tests start peer nodes, which need `epmd`. The tests start it
themselves when it isn't running; in a sandbox that blocks it, run `epmd -daemon`
first. Tests need no external services and no API key of your own.

Running Guardian locally (`iex -S mix`, `make console`) needs `GUARDIAN_API_KEY` of at
least 32 bytes in the environment, for example
`export GUARDIAN_API_KEY="$(openssl rand -hex 32)"`. HTTP is served on port 8080.

## Changes

- Read the nearest `CLAUDE.md` before editing a subsystem. Those files record each
  subsystem's rules for human and AI contributors alike.
- User-visible behavior is specified in [docs/product](docs/product). The design is in
  [docs/architecture](docs/architecture). Update them in the same change when behavior
  or structure changes.
- Keep the ingestion path free of external service calls, and keep tests free of
  external services.
- Add a test with every behavior change, and run the full suite before sending a
  change.

By contributing, you agree that your contributions are licensed under the MIT license
of this repository.
