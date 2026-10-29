# bandit-1141: update Bandit to 1.14.1

## Problem and change

Update the locked Bandit dependency from 1.14.0 to 1.14.1 within the existing
version constraint. No other dependency locks or application settings change;
thousand_island stays at 1.6.0. The
[upstream changelog](https://github.com/mtrudel/bandit/blob/1.14.1/CHANGELOG.md)
and [Hex release](https://hex.pm/packages/bandit/1.14.1) describe the fix for
GHSA-pxjf-g536-7r93
([EEF-CVE-2026-116078](https://osv.dev/vulnerability/EEF-CVE-2026-116078)): an
HTTP/2 request body sent as many 1-byte DATA frames used many times its size in
memory. 1.14.1 collects HTTP/2 bodies into one binary.

Guardian authenticates before it reads a request body, so only a key holder reaching
the listener over HTTP/2 could have triggered this.

## Compatibility

Guardian keeps its existing JSON and MCP responses, authentication, body limits,
timeout settings and request logging. The release's other changes:

- HTTP/2 rejects a request whose `host` header disagrees with `:authority`, or that
  has more than one `host` header, with a stream PROTOCOL_ERROR. Guardian's listener
  is plaintext, so HTTP/2 reaches it only as prior-knowledge h2c. Fly's proxy speaks
  HTTP/1.1 to it unless `h2_backend` is set. Requests through the optional Cloudflare
  Tunnel come from a Worker's `fetch` over a Workers VPC binding; Cloudflare's docs
  do not name the HTTP version of that last leg, which is likely HTTP/1.1 but was not
  verified; either way one client builds both headers from one URL, so they agree.
  A direct h2c client must send a consistent `host` or omit it.
- An oversized HTTP/2 header block now resets only its stream and keeps the HPACK
  state; connection-specific header fields are removed from HTTP/2 responses.
  Guardian adds `connection: close` only outside HTTP/2.
- HTTP/1 header values lose trailing whitespace, so an `x-api-key` value with
  trailing spaces or tabs is compared without them. A malformed bracketed IPv6
  authority such as `[::1]80` is now rejected.
- `Accept-Encoding` q-values follow the RFC grammar; a very long q-value no longer
  causes a 500.
- A 2xx answer to CONNECT closes the HTTP/1 connection. Guardian has no CONNECT
  routes.
- Bandit's transport, HTTP and HTTP/2 exception modules, which Guardian passes
  through to Bandit's error handling, are unchanged.

## Product spec impact

None. No statements in `docs/product/overview.md` or `docs/product/spec.md` change.
`docs/architecture/security.md` now says Bandit, not only Plug, normalizes HTTP/1
header whitespace before key comparison.

## Validation

The transport-error passthrough test now also covers Bandit's HTTP/2 stream and
connection errors, so a renamed module fails to compile. Existing tests cover
authentication, body limits, real-listener requests, MCP and request logging. The
pre-commit gate checks formatting, compilation with warnings as errors and the full
default suite, excluding the existing `:large` tests.

## Deploy notes

After a separately authorized deployment, verify the release uses Bandit 1.14.1,
`GET /health` returns 200, unauthenticated API access remains 401, and authenticated
read-only MCP queries still work. A deployment that enables HTTP/2 to the origin
should first confirm its proxy sends a `host` header consistent with `:authority`. Do not inject test events into production.
