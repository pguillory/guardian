# elixir-1-19-7: build the image with Elixir 1.19.7

## Problem and change

The release image built with Elixir 1.19.6. Elixir 1.19.7 (released 2026-10-29) fixes
two security issues and changes nothing else
([release](https://github.com/elixir-lang/elixir/releases/tag/v1.19.7)):

- CVE-2026-109821: `URI.parse/1` turned every digit of a port into an integer. It now
  trims leading zeros, converts at most six significant digits and gives a nil port
  for longer or out-of-range ones.
- CVE-2026-115274: Elixir's built-in `JSON` decoder, with its default integer
  decoder, now returns `{:error, {:integer_too_large, digits}}` for an integer of more
  than 310 digits instead of converting it.

`ARG ELIXIR_VERSION` in `Dockerfile` goes from 1.19.6 to 1.19.7, which selects the
builder image `hexpm/elixir:1.19.7-erlang-28.5.0.8-debian-trixie-20261027-slim`. Docker
Hub lists that tag for amd64 and arm64. The base images are pinned by tag, not by
digest, so no checksum changes; cloudflared's checksums are unchanged. Erlang/OTP,
Debian and the runner image are unchanged. The local Homebrew toolchain stays on
Elixir 1.19.3.

## Compatibility

Neither issue was exploitable in Guardian:

- Guardian's `url_*` query functions parse through `Guardian.Query.URL`, which already
  cuts out a port of more than 20 digits before calling `URI.parse/1`, and `url_port`
  gives null for a port outside 0 to 65535. Every `url_port` result is the same on
  1.19.6 and 1.19.7. The cut stays: it makes the result, and the copying that keeps a
  short result from holding a long value, the same on every Elixir version.
  `Guardian.Query.URL`'s documentation now describes both behaviors, and its tests
  (`url_test.exs`) no longer assume `URI.parse/1` converts long ports, which failed
  five of seven tests on 1.19.7. `totality_test.exs` comments say the same.
- Guardian decodes JSON with Jason, including MCP requests: `Guardian.Web.MCP.Router`
  checks the admin key, decodes the body with Jason and hands Anubis, the MCP library,
  the decoded map. Anubis calls the built-in `JSON.decode` on raw bodies, but on
  Guardian's path it gets a map and skips them, and they would run only after the
  admin-key check anyway.

## Follow-up

Reconsider the 20-digit cut in `Guardian.Query.URL` once every supported Elixir
release has the fix (1.18.6, 1.19.7 and 1.20.5 do; 1.20.4 doesn't, and `mix.exs`
allows `~> 1.16`). Dropping it would lose the copy guarantee (a long value's host and
authority would stay sub-binaries of it) and would change a 21-digit zero-padded port
such as `000…080` from null to 80.

## Product spec impact

None. No statements in `docs/product/overview.md` or `docs/product/spec.md` change.

## Validation

- The official `elixir-otp-28.zip` from the v1.19.7 release matched its published
  `elixir-otp-28.zip.sha256sum`
  (`3e76be45d819bc65f238c308ad29bcc91e06effeb6508a92f57dd65f48371e5c`). It ran from a
  temporary directory, on a scratch copy of the tree with its own build directory, on
  OTP 28.5.0.8.
- On 1.19.7: Guardian compiles with warnings as errors, and 364 focused tests pass
  with warnings as errors: `url_test.exs`, every `test/guardian/query/function/` test,
  `numeric_test.exs`, `totality_test.exs`, every `test/guardian/web/` test (MCP and
  JSON) and the rules and counters tests the alias change touched. The previous
  `url_test.exs` fails five of its seven tests there. The full suite was not run on
  1.19.7.
- On 1.19.3: the full pre-commit gate (see the commit).
- No Docker build was run, since the development machine has no container runtime.
  Fly's builder builds the image at deploy, and a missing base tag fails that build
  before rollout.

## Deploy notes

After a separately authorized deployment, check:

- The build log shows `hexpm/elixir:1.19.7-erlang-28.5.0.8-debian-trixie-20261027-slim`.
- `GET /health` returns 200, and a request without a key gets 401.
- An authenticated read-only MCP query works, ideally one using `url_port`.
- Ingestion continues.
- When `TUNNEL_TOKEN` is set, the connector registers its tunnel connections.

Don't inject test events. Roll back to the previous image if Guardian fails to come up.
