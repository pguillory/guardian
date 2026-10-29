# cloudflared-2026-10-6: cloudflared 2026.10.6

## Problem and change

The release image pinned cloudflared 2026.10.5. 2026.10.6 bumps go-jose from v4.1.4
to v4.1.6 (VULN-184686), which takes in v4.1.5's panic and parsing fixes and v4.1.6's
fix for GHSA-mgcc-cww5-fp2q (denial of service when parsing JWKs with large RSA keys).
cloudflared parses JWTs and JWKs for Cloudflare Access; the `tunnel run` connector
Guardian starts with a tunnel token is not expected to reach that code (not verified
against cloudflared's call graph), so this is an update for hygiene, not an urgent
fix.

cloudflared goes from 2026.10.5 to 2026.10.6, still built with Go 1.27.3. The version
and both per-architecture SHA-256 checksums in `Dockerfile` change together, keeping
the pin-and-checksum scheme. The checksums are the ones listed in the
[official release](https://github.com/cloudflare/cloudflared/releases/tag/2026.10.6).
`THIRD_PARTY_NOTICES.md` names the new version. The Debian base, Elixir and
Erlang/OTP are unchanged.

## Compatibility

Guardian itself is unchanged. These are the cloudflared changes between 2026.10.5 and
2026.10.6
([release notes](https://github.com/cloudflare/cloudflared/blob/2026.10.6/RELEASE_NOTES)):

- VULN-184686: go-jose v4.1.4 to v4.1.6.
- TUN-11018: the tunnel's QUIC settings move into one shared constructor, with the
  same values as before (including the initial packet sizes), so the diagnostic-only
  connectivity prechecks use the tunnel's own transport settings, edge bind address
  and IP version.
- TUN-11048 and TUN-11051: the Linux service's update timer, the RPM package marker,
  and `NO_AUTOUPDATE` in Cloudflare's own container images. Guardian runs the binary
  from `bin/fly-start` with `--no-autoupdate` and installs no service.
- Base-image digest updates and CI changes in Cloudflare's own build.

The `bin/fly-start` options `--no-autoupdate`, `--metrics`,
`--management-diagnostics` and `--grace-period` are untouched by this range, so the
entry script is unchanged.

## Product spec impact

None. No statements in `docs/product/overview.md` or `docs/product/spec.md` change.

## Validation

- Both binaries were downloaded from the release and hashed locally. They match the
  checksums listed on the release page and GitHub's asset digests, and both embed
  go1.27.3. The release is not a prerelease.
- No Docker build was run, since the development machine has no container runtime.
  Fly's builder builds the image at deploy. A checksum mismatch fails that build
  before rollout, and the image's `cloudflared --version` step fails it if the
  binary doesn't run.

## Deploy notes

The image is built at deploy, and a checksum failure stops the deploy before rollout.
After a separately authorized deployment, check:

- The `cloudflared --version` step in the build log prints 2026.10.6.
- `GET /health` returns 200, and a request without a key gets 401.
- When `TUNNEL_TOKEN` is set, the connector registers its tunnel connections (in the
  Fly logs), and a read-only request through the Workers VPC path still reaches
  Guardian.

Don't inject test events. Roll back to the previous image if the connector or
Guardian fails to come up.
