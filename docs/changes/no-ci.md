# no-ci: local checks at commit time

## Problem

The repository ran tests and a Docker build through GitHub Actions on pushes and
pull requests. Tests belong in local commit checks rather than hosted CI.

## Behavior after the change

The GitHub Actions workflow is removed. Never add GitHub Actions or other hosted
CI: tests run locally at commit time. The existing `bin/pre-commit` hook checks
staged whitespace and formatting, compiles with warnings as errors, and runs the
full test suite with warnings as errors. Hook setup is in
`docs/guides/development.md`.

Per-push Linux test runs and image builds are removed. Docker builds are checked
locally when needed, rather than on each push. The
Elixir and Erlang/OTP version pins remain in `Dockerfile`; image behavior is
unchanged. The arm64 image remains untested (`TODO.md arm64-image`).

## Product spec impact

None. Guardian's runtime behavior and interfaces are unchanged.

## Validation

- Checked the workflow removal and documentation for stale hosted-check claims.
- Local pre-commit formatting, compilation, and full-suite checks run at commit time.
- No Docker build: only the Dockerfile's architecture comment changed.
