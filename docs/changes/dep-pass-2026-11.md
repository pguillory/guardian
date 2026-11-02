# dep-pass-2026-11: cloudflared 2026.10.7 and elixir_make 0.10.1

## Problem and change

A routine dependency pass on November 2, 2026, taking only versions published at
least 48 hours earlier. None of this is a security fix: the advisory feeds list
nothing against Guardian's Hex packages.

- cloudflared goes from 2026.10.6 to 2026.10.7, still built with Go 1.27.3. The version
  and both per-architecture SHA-256 checksums in `Dockerfile` change together.
  `THIRD_PARTY_NOTICES.md` names the new version.
- `elixir_make` goes from 0.10.0 to 0.10.1, a build-time dependency, in `mix.lock`
  only. It is the only package in the lock diff.

Already current: the Debian base `trixie-20261027-slim`, Elixir 1.19.7 and Erlang/OTP
28.5.0.8 are each the newest on their line, and every other direct Hex package is at
its latest release.

## Held back

- `nimble_options` 1.2.0 (transitive): published the day of this pass, so it is under
  48 hours old, with no advisory. It stays at 1.1.1, which is why the update names
  `elixir_make` rather than updating everything.
- `peri` 0.12.0 (transitive): published the day before this pass, so under 48 hours
  old, and Anubis 2.2.0 requires `~> 0.11.2`, so it moves with Anubis.
- `hypex` 2.x: held at 1.x for the reasons in `docs/architecture/system.md`, section
  10.
- Elixir 1.20.5 and Erlang/OTP 29.1.2 images: a new minor and a new major, each a
  deliberate change of its own. Guardian's source and default suite passed on Elixir
  1.20.4 with OTP 28 ([the compatibility change](elixir-120-compatibility.md)), but
  dependencies still warn there, the local toolchain would fall further behind the
  image, and the 1.20.5 image has not been validated. OTP 29 has no such record.

## Compatibility

Guardian itself is unchanged. These are the cloudflared changes between 2026.10.6 and
2026.10.7
([release notes](https://github.com/cloudflare/cloudflared/blob/2026.10.7/RELEASE_NOTES)):

- TUN-11058: over the HTTP/2 transport, Go 1.27 had capped concurrent streams at 250.
  The limit is effectively unlimited again, as before Go 1.27, so with that transport
  the tunnel can pass more concurrent requests to Guardian than the Go 1.27 builds did.
  QUIC is cloudflared's default transport.
- TUN-10904: the connector stops advertising legacy features to the edge, including
  `allow_remote_config` and `management_logs`, and no longer advertises
  `support_datagram_v2` by default. Upstream's stated reason is that the edge supports
  the legacy ones universally. That
  edge behavior can't be verified from the source, and a token-run connector may rely
  on these features, so the deploy checks below are what confirm it.

Nothing under cloudflared's `cmd/` changes, so the `bin/fly-start` options
`--no-autoupdate`, `--metrics`, `--management-diagnostics` and `--grace-period` are
untouched and the entry script is unchanged.

`elixir_make` 0.10.1 raises the header limit of its HTTP downloader and reports
precompiled-NIF download errors properly. Guardian builds its NIFs with `make`, sets no
precompiler and doesn't use the downloader.

## Product spec impact

None. No statements in `docs/product/overview.md` or `docs/product/spec.md` change.

## Validation

- Both cloudflared binaries were downloaded from the release and hashed locally. They
  match the checksums listed on the release page and GitHub's asset digests, and both
  embed go1.27.3. The release is not a prerelease.
- The Docker Hub API lists the unchanged base image tags for amd64 and arm64.
- No Docker build was run, since the development machine has no container runtime.
  Fly's builder builds the image at deploy. A checksum mismatch fails that build
  before rollout, and the image's `cloudflared --version` step fails it if the
  binary doesn't run.
- The pre-commit gate passed: formatting, compiling with warnings as errors, and the
  full default suite. The suite doesn't run the Linux binary or build the image.

## Deploy notes

The image is built at deploy, and a checksum failure stops the deploy before rollout.
After a separately authorized deployment, check:

- The `cloudflared --version` step in the build log prints 2026.10.7.
- `GET /health` returns 200, and a request without a key gets 401.
- When `TUNNEL_TOKEN` is set, the connector registers its tunnel connections (in the
  Fly logs), and a read-only request through the Workers VPC path still reaches
  Guardian. This is the check on TUN-10904. If the tunnel's remote management or log
  streaming is in use, look at that too.

Don't inject test events. Roll back to the previous image if the connector or
Guardian fails to come up.
