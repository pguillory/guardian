# Building and development

## Prerequisites

- Elixir and Erlang/OTP: use the versions the image builds with, `ELIXIR_VERSION` and
  `OTP_VERSION` in the [`Dockerfile`](../../Dockerfile)
- a C toolchain
- `epmd`, which ships with Erlang, for the multi-node tests

## Building and testing

```sh
mix deps.get
mix test --warnings-as-errors
```

`iex -S mix` and `mix run` need `GUARDIAN_API_KEY` (32 bytes or more) in the
environment and serve HTTP on port 8080. Tests use their own fixed configuration.
Before committing, run `bin/install-git-hooks` once; the hook checks formatting,
compiles with warnings as errors, and runs the suite. See
[CONTRIBUTING.md](../../CONTRIBUTING.md).
