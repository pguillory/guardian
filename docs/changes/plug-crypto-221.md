# plug-crypto-221: update the crypto dependency

## Problem and change

Update the locked `plug_crypto` dependency from 2.2.0 to 2.2.1, within Plug's
existing version constraint. This fixes CVE-2026-105963: wrong-typed arguments can
put secrets in exception stack arguments. See the
[vendor advisory](https://github.com/elixir-plug/plug/security/advisories/GHSA-ffw9-w85g-f2vh),
[upstream changelog](https://github.com/elixir-plug/plug_crypto/blob/v2.2.1/CHANGELOG.md)
and [Hex release](https://hex.pm/packages/plug_crypto/2.2.1).

No attacker-influenced wrong-typed call path was identified in Guardian. Its only
direct call is `Web.Auth`'s `secure_compare/2`, reached only with binary credentials;
missing and structured credentials are rejected first. Guardian does not enable
Phoenix tokens, Plug sessions, signed cookies or the Plug debugger. Generic errors
can carry stack arguments into stdout and Bandit crash metadata, but HTTP error
responses do not return those stacks. External log-export settings were not checked.
This is a routine dependency patch; it does not change authentication behavior.

## Product spec impact

None. No statements in `docs/product/overview.md` or `docs/product/spec.md` change.

## Validation

The pre-commit hook checks formatting, compilation with warnings as errors and the
full default test suite (the existing `:large` exclusions apply). Existing
authentication tests cover missing credentials and list/map-shaped query
credentials on both authenticated routers.
