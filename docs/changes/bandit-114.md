# bandit-114: update the HTTP server dependency

## Problem and change

Update the locked Bandit dependency from 1.13.1 to 1.14.0 within the existing
version constraint. No other dependency locks or application settings change.
The [upstream changelog](https://github.com/mtrudel/bandit/blob/1.14.0/CHANGELOG.md)
and [Hex release](https://hex.pm/packages/bandit/1.14.0) describe twelve
advisory-linked fixes across HTTP/1, HTTP/2 and WebSockets. These include excess
memory use from tiny HTTP/1 chunks (CVE-2026-111101), quadratic parsing of numeric
header values (CVE-2026-113436), and chunk-extension/trailer request smuggling
(CVE-2026-114216).

HTTP parsing happens before Guardian authenticates requests. How much malformed
traffic a deployment's proxy forwards was not tested; no claim is made that every
advisory is exploitable through a particular proxy. Guardian has no WebSocket routes.

## Compatibility

Guardian keeps its existing JSON and MCP responses, authentication, body limits,
timeout settings and request logging. The dependency has these transport changes:

- HTTP/1 now rejects loosely parsed versions, extra request-line words and ambiguous
  absolute-form targets with 400. Chunk extensions must follow the RFC grammar and
  trailer lines must end in CRLF; optional whitespace before an extension's `;` is
  now accepted. Normal origin-form API requests are unchanged.
  Absolute-form port zero is now preserved in the Plug connection, and therefore
  in Guardian's request logs, rather than replaced by the scheme's default port.
- HTTP/2 now advertises at most 500 concurrent streams and 262,144 header-list bytes
  by default, bounds receive windows and queued work, and rejects invalid stream
  transitions. Guardian does not override those defaults.
- An HTTP/2 body read can coalesce more than its requested length into its final
  chunk, with overshoot bounded by the 1 MiB stream receive window. Bandit's
  `HTTP2.Stream` returns `:more` when the cumulative length is
  exceeded, even if that DATA frame ends the stream; Plug's JSON parser maps this
  to 413. MCP also explicitly checks the byte size of an `:ok` body. The 8 MB cap
  therefore remains enforced. Exactly at the cap without Content-Length, a read
  can now return `:more` before a separately arriving END_STREAM, producing 413.
- HTTP/2 body reads use a deadline extended in proportion to actual data, so empty
  frames no longer keep a read alive. Slow or incomplete requests can end sooner
  even though Guardian's timeout settings do not change. HTTP/1 body reading uses
  the same timeout interface and now collects tiny chunks into a binary.
- Guardian already passes Bandit's transport, HTTP and HTTP/2 exceptions through
  to Bandit's error handling. Its web logger uses Plug connection fields and its
  own response-body length, not Bandit's telemetry byte counts. No error-handler
  or logger adaptation is needed.

## Product spec impact

None. No statements in `docs/product/overview.md` or `docs/product/spec.md` change.
The HTTP/2 exact-cap framing case described above is an accepted upstream boundary
change; bodies over 8 MB still receive 413.

## Validation

A real-listener regression test sends an authenticated JSON query as one-byte
HTTP/1 chunks and checks the decoded success response and absence of exception
logs. This checks compatibility, not the upstream memory bound. Existing tests
cover authentication, 400/413 body errors, transport-error passthrough, split
malformed bodies with Expect, sanitized real-listener failures, MCP and request
logging. The pre-commit gate checks formatting, compilation with warnings as
errors and the full default suite, excluding the existing `:large` tests.
The focused JSON API, authentication routes, logger and MCP body run passed:
48 tests, zero failures.

## Deploy notes

After a separately authorized deployment, verify the release uses Bandit 1.14.0,
`GET /health` returns 200, unauthenticated API access remains 401, and authenticated
read-only JSON queries and MCP initialization/query calls still work. Check existing
ingestion continues and request/response logs and error rates remain normal. Do not
inject test events into production or send resource-exhaustion probes.
