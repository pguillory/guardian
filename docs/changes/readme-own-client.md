# readme-own-client: no official clients; the README shows a helper you write

The README's copies of the Fly guide's commands and the JavaScript helper were
dropped in [plain-setup](plain-setup.md): the README links the guide, and the helper
is `send_event` in Python.

## Problem

The README's walkthrough used an official Python client, and its Connecting section
named clients for Python, TypeScript, Elixir and Rust ([readme-walkthrough](readme-walkthrough.md)).
None exist, and the owner decided against shipping them: sending an event is one HTTP
request, which a reader can wrap in a few lines. The README's setup was also spread
over Run it, Connecting (with Docker, Codex and client examples) and a "What it isn't"
section that copied the known-limitations page.

## Change

1. The walkthrough calls `event(table, fields, returning=...)`, a helper the reader
   writes, and its query result is a Markdown table with the same values.
2. Run it is three steps: deploy on Fly (the Fly guide's commands, linked for the
   details), send an event with one curl, and connect Claude Code with
   `claude mcp add`. The Docker steps move to a link to the single-node guide; the
   Codex configuration is dropped.
3. A new section, Sending events from your code, gives the helper in Python (standard
   library only) and JavaScript (`fetch`), with the timestamp note and a link to the
   API reference.
4. "What it isn't" is removed. Its points are in
   [Known limitations](../reference/limitations.md) (single principal, retention, no
   replication, crash loss) and the product overview's "What it is not" (no joins or
   subqueries, no UI, dashboards or alerting, no users or namespaces); the intro keeps
   the one most readers need, that events expire after about 15 days, with the
   limitations link.
5. TODO.md's `clients` item is removed.
6. The commands in Run it are the Fly guide's, verbatim, and `test/guardian/deployment_test.exs`
   checks that each of the guide's command blocks it copies appears in the README, so
   the two can't drift (TODO.md readme-guide-copies).
7. Step 3 notes that Claude Code keeps the admin key in its own configuration, and
   warns against `--scope project`, which would write it into the project's `.mcp.json`.

## Product spec impact

None. No client library was ever specified in `docs/product/overview.md` or
`docs/product/spec.md`.

## Validation

Both helpers and the curl, copied from the README with only the URL replaced, ran
against a local Guardian with throwaway keys: the walkthrough's calls returned the
stored event and `{"is_blocked": null}` (`None` in Python) before any rule.
`claude mcp add --transport http <name> <url> --header ...` matches `claude mcp add --help`
(Claude Code 2.1.312).
