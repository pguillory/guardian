# Contributing

Thanks for your interest in Guardian.

## Setup and checks

[docs/guides/development.md](docs/guides/development.md) has the prerequisites, the
setup (`mix deps.get`, `bin/install-git-hooks`), the checks the pre-commit hook runs
at every commit, and how to run Guardian locally.

## Changes

- Before editing a file under `lib/`, read every existing `CLAUDE.md` from `lib/`
  down to the file's directory. Those files record each subsystem's rules for
  human and AI contributors alike; adjacent `AGENTS.md` symlinks share those rules.
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

By contributing, you agree that your contributions are licensed under the MIT license
of this repository.
