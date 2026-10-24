# Contributing

Thanks for your interest in Guardian.

## Setup and checks

[docs/guides/development.md](docs/guides/development.md) has the prerequisites, the
setup (`mix deps.get`, `bin/install-git-hooks`), the checks the pre-commit hook runs
at every commit, and how to run Guardian locally.

## Changes

- Read the nearest `CLAUDE.md` before editing a subsystem. Those files record each
  subsystem's rules for human and AI contributors alike.
- User-visible behavior is specified in [docs/product](docs/product). The design is in
  [docs/architecture](docs/architecture). Update them in the same change when behavior
  or structure changes.
- Keep the ingestion path free of external service calls, and keep tests free of
  external services.
- Add a test with every behavior change, and run the full suite before sending a
  change.

By contributing, you agree that your contributions are licensed under the MIT license
of this repository.
