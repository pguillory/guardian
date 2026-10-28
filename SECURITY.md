# Security policy

## Reporting a vulnerability

Please report suspected vulnerabilities privately, not in a public issue.

Use GitHub's private vulnerability reporting: on this repository's Security tab, choose
"Report a vulnerability". The report is visible only to the maintainer until a fix is
published.

Include what you found, how to reproduce it, and the version or commit you tested.

## Scope

Guardian is single-tenant: the admin key grants full access to every table and the
rules, and its holders are trusted. The insert-only ingest key is meant for
applications: it can send events but not run queries or read or change rules. The
deprecated `GUARDIAN_API_KEY` has full access like the admin key while it is set.
Reports that matter most:

1. Reading or writing event data without a key.
2. Recovering a key from Guardian's responses, logs or stored tables.
3. The ingest key running a query, reading or changing rules, or reaching MCP. What it
   can do by design (read back its own events after rules through `return_keys`,
   including counter values, and write any table, built-in ones included) is listed in
   [docs/architecture/security.md](docs/architecture/security.md).
4. A key holder causing harm beyond the event store: code execution, file access or
   network access from a query.
5. A way in through Erlang distribution on a single node, which listens only on
   loopback.

Out of scope, by design (see [docs/architecture/security.md](docs/architecture/security.md)):

- anything an admin-key holder can do with the store itself
- anyone with the Erlang cookie and network access to a cluster's distribution ports
- resource exhaustion by a key holder beyond the documented limits
