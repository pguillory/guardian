# elixir-120-compatibility: warning-free Guardian compilation

## Problem

Elixir 1.20 reports Guardian compiler warnings that fail the local
`--warnings-as-errors` checks, even though the same source compiles on 1.19.

## Behavior after the change

Pin externally bound bitstring sizes, remove unused requires, and call optional
function evaluators with `apply/3` after the existing export check. Remove the
unreachable two-element success match for `DateTime.from_iso8601/1`, retaining the
existing `NaiveDateTime` parsing path. Segment bytes and query results stay the same.
Test-only compatibility changes pin the golden file's external size, invoke
deliberately invalid inputs dynamically, and separate assertions from expressions
the compiler can prove always succeed.

The dead timestamp branch exposed a separate bug: nonzero ISO8601 offsets were
discarded by the existing fallback. This was addressed separately, outside this
compatibility change; time arithmetic now accepts only Guardian's UTC format and
rejects offsets (`docs/changes/timestamp-offsets.md`).

The local runtime and Docker pins remain unchanged. Compatibility checks use the
official Elixir 1.20.4 `elixir-otp-28.zip` release from
[elixir-lang/elixir](https://github.com/elixir-lang/elixir/releases/tag/v1.20.4),
verified against the release's `elixir-otp-28.zip.sha256sum`, extracted into a
temporary directory and selected only for individual commands.
The verified SHA-256 is
`ea7ff98bc1ed76c663a5d034c863c6fd37e65c9c855b6bbf6ccb2034d806673c`.

## Product spec impact

None. No statements in `docs/product/overview.md` or `docs/product/spec.md` change.

## Validation

- Formatting passes on Elixir 1.19.3. Forced Guardian compilation with warnings as
  errors passes on Elixir 1.19.3 and 1.20.4, both on OTP 28.5.0.8 with two schedulers.
- The full default suite passes on both versions: 970 tests, zero failures, with
  the three memory-intensive `:large` tests excluded by the existing test setup.
  Those tests were not run.
- The first 1.20 suite run passed its assertions but exited with failure because
  four test-source warnings remained. After the test-only compatibility changes,
  the full rerun exits successfully without compiler warnings.
- Separate build directories keep the Elixir artifacts apart; the pre-commit hook
  repeats the 1.19 checks after the 1.20 run against the shared native outputs.

Third-party dependencies still emit warnings on fresh builds: `superlist` (Range
step), `uuid` (Bitwise), `hypex` (bitstring sizes), `peri` (type checking and redundant
clauses), and `anubis_mcp` (unused require, redundant clauses, logging macros and
optional Redix calls). Development formatting also exposes `exsync` struct-update
warnings. They do not fail Guardian's warnings-as-errors checks and dependency
changes are outside this work.
