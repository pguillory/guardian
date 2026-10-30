# release-cookie-file: the Erlang cookie stays off the command line

## Problem and change

The generated `bin/guardian` passes `--cookie "$RELEASE_COOKIE"`, which puts
`-setcookie <value>` on the command line of the server's `beam.smp` and of every
`remote` and `rpc` node. Mix has no option against it, and `vm.args`, `-args_file` and
`ERL_AFLAGS` all end up in the same command line. Anything that lists processes sees
the cookie, and `fly deploy` prints the table of listening processes when it warns that
an app isn't listening on the expected address, so the cookie can land in deploy logs.

Now no Guardian process has the cookie on its command line, in any mode:

1. A custom release step in `mix.exs` removes the four `--cookie` arguments from
   `bin/guardian`. It fails the build if the script doesn't have them or passes the
   cookie any other way, so an Elixir upgrade can't quietly restore them.
2. `rel/env.sh.eex` writes the cookie to an owner-only `.erlang.cookie` and sets `HOME`
   to that directory for the VM. With no `-setcookie`, OTP reads `$HOME/.erlang.cookie`
   before anything else. An XDG path wouldn't do: a real `~/.erlang.cookie` wins over it.
3. The value still comes from `RELEASE_COOKIE`, or from `releases/COOKIE` on a single
   node. There is no new secret or setting.

The server's file is `<RELEASE_TMP>/cookie/.erlang.cookie`. OTP reads it again on
`System.restart`, so clients never touch it: `remote`, `rpc`, `stop`, `restart` and `pid`
write `~/.guardian-cookie-<uid>/.erlang.cookie`, in the release's tmp directory if the
user doesn't own `HOME`, and refuse if they own neither. That also keeps a root client
under `sudo` from leaving the service a file it can't read. `eval` and the other commands
start no distribution and write nothing.

Clients write only under a directory the user owns because whoever can write to a parent
directory can swap the path for a symlink, which `chmod` and `test -O` follow. That rules
out `/tmp`, and under root it rules out a service account's tmp directory and a home kept
from the calling user. A client never creates a missing tmp directory: nothing is
running without one, and a root-owned one would stop the service's first start.

The alternative was `-nocookie` plus `Node.set_cookie` from Guardian's code, with no file.
It was rejected: clients boot with the clean script, so no Guardian code runs before
they connect, and Elixir's `--eval` isn't ordered against `--remsh`.

## Compatibility

1. Older releases: they ignore the file and keep passing the cookie on the command
   line, from the same `RELEASE_COOKIE`. Rollback needs no step.
2. Rolling deploys: for a printable ASCII cookie the value is the same on both sides, so
   old and new nodes connect. Tested in both directions between an unmodified and a
   changed release.
3. Cookies: OTP's file reader accepts only printable ASCII and drops trailing CR and LF.
   A cookie with other bytes, which the command line used to allow, fails at boot with
   "Bad characters in cookie", without printing it. One with a trailing line ending would
   differ from an old node's value. The guides' generated cookies have neither.
4. `HOME`: the VM's `HOME` is the cookie directory. Guardian reads nothing from `HOME`,
   the rule store doesn't enable Req's netrc step, and `bin/fly-start` starts cloudflared
   outside `env.sh`. A remote console no longer sees the operator's `~/.iex.exs`,
   `~/.erlang` or shell history.
5. `sudo`: a client under `sudo` that keeps the caller's `HOME`, on a release a service
   account owns, refuses until `HOME` is set to a directory root owns.
6. Known limits: the files stay on disk after a command exits. Two clients of one user with different cookies at the same moment can
   read each other's file, and one is refused. A second `start` by the server's user
   rewrites the server's file before it refuses on the name clash, so a different cookie
   there would apply at the next `System.restart`.

## Product spec impact

One statement is added to `docs/product/spec.md`, in the cluster list's item on the
cookie: "Guardian's own processes (the server, the remote console and rpc commands) never
carry the cookie on their command lines." `docs/product/overview.md` is unchanged.

## Validation

- `test/guardian/deployment_test.exs` covers the files, modes and paths, the fallbacks,
  refusals, the release script from Mix's own template, the build guard, and OTP reading
  the file.
- A real release on macOS, with a throwaway cookie, on loopback, in cluster and
  single-node modes: `ps` showed no `-setcookie` on the server or a live `remote`; `rpc`,
  `pid`, `stop`, `restart` and `eval` worked, and a wrong cookie was refused. The local
  run removes `+sbt ts` from a copy's `vm.args`, since macOS doesn't support it.
- The release was built with Elixir 1.19.3. The image's 1.19.7 has the same four
  arguments in its template, and the build fails if it doesn't. No Docker build or Linux
  boot was run, since the development machine has no container runtime.

## Deploy notes

Before the first deploy, check the production cookie is printable ASCII: one machine's
`RELEASE_COOKIE` should count zero bytes outside that range. A cookie that fails this
stops the rolling deploy at its first machine. After the deploy, count `-setcookie`
matches in the machine's process list, which should be zero, and connect with
`bin/guardian remote`. The value that was on the command line before this change should
be treated as exposed in whatever logs it reached, and rotated by the operator.
