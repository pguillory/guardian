# Security policy

## Reporting a vulnerability

Please report suspected vulnerabilities privately, not in a public issue.

Use GitHub's private vulnerability reporting: on this repository's Security tab, choose
"Report a vulnerability". The report is visible only to the maintainer until a fix is
published.

Include what you found, how to reproduce it, and the version or commit you tested.

## Scope

Guardian is single-tenant: one API key grants full access to every table, and key
holders are trusted. Reports that matter most:

1. Reading or writing event data without the key.
2. Recovering the key from Guardian's responses, logs or stored tables.
3. A key holder causing harm beyond the event store: code execution, file access or
   network access from a query (for example through `jq()`).
4. A way in through Erlang distribution on a single node, which listens only on
   loopback.

Out of scope, by design (see [docs/architecture/security.md](docs/architecture/security.md)):

- anything a key holder can do with the store itself
- anyone with the Erlang cookie and network access to a cluster's distribution ports
- resource exhaustion by a key holder beyond the documented limits
