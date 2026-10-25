# Building and development

## Prerequisites

- Elixir and Erlang/OTP: the image pins Elixir 1.19.6 and OTP 28.5.0.8 in the
  [`Dockerfile`](../../Dockerfile). The local Homebrew setup uses Elixir 1.19.3
  with the same OTP 28.5.0.8.
- a C toolchain
- `epmd`, which ships with Erlang, for the multi-node tests

Guardian's own source compiles with warnings as errors on Elixir 1.19 and 1.20
with OTP 28 (checked on 1.19.3 and 1.20.4). The installed runtime and image pins
above remain unchanged. Some dependencies still emit warnings on a fresh build;
see [the compatibility change](../changes/elixir-120-compatibility.md).

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

## Setup

```sh
mix deps.get
bin/install-git-hooks
```

`mix deps.get` fetches the dev dependencies too, and the formatter needs them
(`freedom_formatter` is a dev-only plugin), so run it without `--only`.
`bin/install-git-hooks` links `bin/pre-commit` as the repository's pre-commit hook.
It works from linked worktrees and honors a repository-local `core.hooksPath`,
including relative paths. It refuses a hooks path configured outside the repository's
local/worktree configuration, so it cannot replace a shared global hook. The link
targets the main checkout's `bin/pre-commit` and checks whichever worktree is being
committed. With the default or an absolute hooks path, it survives removal of the
installing worktree; a relative hooksPath lives inside each worktree. Changes to the hook on
a branch therefore need to be run directly to test that branch's version. A layout
without an executable `bin/pre-commit` beside the common Git directory is refused.

## Checks

These are Guardian's only checks: there is no hosted CI, and none may be added. The
pre-commit hook checks staged whitespace (`git diff-index --check --cached`) and then
runs, on the working tree:

```sh
mix format --check-formatted
MIX_ENV=test mix compile --warnings-as-errors
mix test --warnings-as-errors
```

Run `mix format` to fix formatting, including when passing explicit file paths or
stdin (`mix format -`). The build-only `Guardian.Formatter` plugin in
`.formatter.exs` applies FreedomFormatter twice per input to handle its
[newly wrapped trailing-comma bug](https://github.com/marcandre/freedom_formatter/issues/9).
This retains Guardian's existing style and makes one invocation pass the check.
Run the full suite after every change. The multi-node tests start peer nodes,
which need `epmd`; the tests start it themselves
when it isn't running, and in a sandbox that blocks that, run `epmd -daemon` first.
Tests need no external services (no PostgreSQL, Memcached or GeoIP files) and no API
key of your own: they use their own fixed configuration. Tests tagged `:large`
allocate gigabytes and are excluded; run them by hand with `mix test --only large`.

## Running locally

`iex -S mix`, `mix run --no-halt` and `make console` need `GUARDIAN_API_KEY` of at least 32
bytes in the environment, for example
`export GUARDIAN_API_KEY="$(openssl rand -hex 32)"`, and serve HTTP on port 8080.

## Docker image architectures

The image's architecture support is stated once, in
[system.md section 10.1](../architecture/system.md#101-build).
