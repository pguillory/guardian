# Contributing

Thanks for your interest in Guardian.

## Setup and checks

[docs/guides/development.md](docs/guides/development.md) has the prerequisites, the
setup (`mix deps.get`, `bin/install-git-hooks`), the checks the pre-commit hook runs
at every commit, and how to run Guardian locally.

## Changes

- Before editing a file under `lib/`, read every existing `AGENTS.md` from `lib/`
  down to the file's directory. Those files record each subsystem's rules for
  human and AI contributors alike. AGENTS.md is the canonical real instruction
  file at every level. Codex loads only the path to its starting directory, so
  explicitly read applicable descendant instructions before editing.
- User-visible behavior is specified in [docs/product](docs/product). The design is in
  [docs/architecture](docs/architecture). Update them in the same change when behavior
  or structure changes.
- Keep the ingestion path free of external service calls, and keep tests free of
  external services.
- Add a test with every behavior change, and run the full suite before sending a
  change.

## Elixir style

Always write function and macro definitions with `do...end` blocks, including
`def`, `defp`, `defmacro`, `defmacrop`, and `defn`-style variants. Do not use the
keyword body form (`def example(value), do: value`), even for a single expression.
Keyword-form `if`, `case`, and `unless` expressions are fine.

The normal test suite checks this rule in `lib/`, `libtest/`, and `test/`, including
definitions inside quoted code. Declarations without bodies and `defdelegate` are
unaffected.

Define one module per file under `lib/` and `libtest/`, at the path matching its
name, including exceptions and structs that belong to another module
(`Guardian.Rules.Runtime.Failure` lives in `lib/guardian/rules/runtime/failure.ex`).
A `defimpl` stays in the file of the protocol or struct it implements; the vendored
DistributedStream `Enumerable` implementation keeps its own file. The same scan test
checks that each file defines at most one module, counting nested `defmodule` and
`defprotocol` but not quoted code or `defimpl`.
Test files may still define small support modules inline.

Give every alias its own line: `alias Guardian.Counters.Budget` and
`alias Guardian.Counters.Clock`, never `alias Guardian.Counters.{Budget, Clock}`. Each
module's full name stays greppable, and adding or removing one alias is a one-line
diff. Credo's `MultiAlias` check enforces this in the pre-commit hook (`mix credo`);
`.credo.exs` enables only that check. Grouped `import` and `require` aren't checked,
and Guardian has none.

Put new shared test infrastructure under `Guardian.Test.*` in
`libtest/guardian/test/`, split by concern; see the
[test support namespace](docs/changes/test-support-namespace.md) for existing helpers
and their concurrency requirements.

Generic mechanisms belong in generic layers, not inside a feature module (for example,
an object-store lock would be a generic lock-on-a-key in the S3/R2 client, not part of
Rules).

By contributing, you agree that your contributions are licensed under the MIT license
of this repository.
