# Building and development

## Prerequisites

- Elixir and Erlang/OTP: the image pins Elixir 1.19.6 and OTP 28.5.0.8 in the
  [`Dockerfile`](../../Dockerfile). The local Homebrew setup uses Elixir 1.19.3
  with the same OTP 28.5.0.8.
- a C toolchain
- `epmd`, which ships with Erlang, for the multi-node tests

## Local Homebrew runtime

Use `erlang@28`, not the unversioned `erlang` formula, which now tracks OTP 29.
Elixir 1.19.3 invokes `erl` from `PATH` and runs on OTP 28.5.0.8 without
reinstalling Elixir. OTP 28.2 can crash the VM when a process is killed while
`re:run` yields ([upstream issue](https://github.com/erlang/otp/issues/10432));
the fix shipped in [OTP 28.3](https://www.erlang.org/patches/otp-28.3).

With Homebrew on Apple Silicon, link the installed `erlang@28` into
`/opt/homebrew/bin` so ordinary `mix` commands and the pre-commit hook use it.
When switching from an existing unversioned `erlang` installation:

```sh
brew unlink erlang
brew link --force erlang@28
elixir --version
erl -noshell -eval '{ok, V} = file:read_file(filename:join([code:root_dir(), "releases", "28", "OTP_VERSION"])), io:put_chars(V), halt().'
```

The installed runtime is OTP 28.5.0.8 with wxWidgets 3.2.12. When installing
Homebrew runtimes, inspect dependency changes first; keep
`HOMEBREW_NO_AUTO_UPDATE=1` and `HOMEBREW_NO_INSTALL_CLEANUP=1` set during a
targeted switch. Do not run an unqualified `brew upgrade`: upgrading `elixir`
or unversioned `erlang` would move this setup to Elixir 1.20 / OTP 29.

Existing BEAM processes retain their original runtime until restarted. Use a
scratch checkout for isolated builds: Guardian's native compilation writes to
`priv/` even with a separate `MIX_BUILD_PATH`.

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
