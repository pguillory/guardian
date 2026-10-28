# image-refresh-1027: cloudflared 2026.10.5 on Debian trixie-20261027

## Problem and change

The release image pinned cloudflared 2026.10.1 (Go 1.27.2) and Debian
trixie-20261020. This change updates both, and removes a stale branch. The
cloudflared range includes Go 1.27.3 and two upstream security fixes: VULN-176088
(an allowlist for the metrics server's debug endpoints) and VULN-183456 (go-chi).

- cloudflared goes from 2026.10.1 to 2026.10.5, which is built with Go 1.27.3. The
  version and both per-architecture SHA-256 checksums in `Dockerfile` change
  together. The checksums are the ones listed in the
  [official release](https://github.com/cloudflare/cloudflared/releases/tag/2026.10.5).
  `THIRD_PARTY_NOTICES.md` names the new version.
- The Debian base goes from `trixie-20261020-slim` to `trixie-20261027-slim`. That
  one `DEBIAN_VERSION` argument selects both the builder image
  (`hexpm/elixir:1.19.6-erlang-28.5.0.8-debian-trixie-20261027-slim`) and the runner
  image (`debian:trixie-20261027-slim`). Both tags exist for amd64 and arm64. The
  Elixir and Erlang/OTP pins are unchanged.
- The remote branch `11642` is deleted. It still carried the GitHub Actions workflow
  that [no-ci](no-ci.md) removed from main. Main already contains all of its
  commits.

## Compatibility

Guardian itself is unchanged. These are the cloudflared changes between 2026.10.1 and
2026.10.5
([release notes](https://github.com/cloudflare/cloudflared/blob/2026.10.5/RELEASE_NOTES)):

- Go 1.27.3, and dependency bumps (go-chi, klauspost/compress).
- A fix for dropping the tail of a message larger than the buffer (TUN-10994).
- The metrics server serves an explicit allowlist of debug handlers in place of
  everything mounted under `/debug/`. The `x/net/trace` pages (`/debug/requests`,
  `/debug/events`) are gone. `bin/fly-start` keeps that listener on
  `127.0.0.1:20241`, and nothing in Guardian probes it.
- The connector's QUIC metrics ignore unchanged fields in MetricsUpdated events,
  which affects only its local metrics.
- `ingress validate` can read from stdin, and access commands no longer require
  `--fedramp`. `tunnel run` uses neither.

The `bin/fly-start` options `--no-autoupdate`, `--metrics`,
`--management-diagnostics` and `--grace-period` all still exist at the 2026.10.5 tag,
so the entry script is unchanged.

## Product spec impact

None. No statements in `docs/product/overview.md` or `docs/product/spec.md` change.

## Validation

- Both binaries were downloaded from the release and hashed locally. They match the
  checksums listed on the release page and GitHub's asset digests, and both report
  go1.27.3.
- The Docker Hub API lists both base image tags, for amd64 and arm64.
- No Docker build was run, since the development machine has no container runtime.
  Fly's builder builds the image at deploy. A checksum mismatch or a missing base tag
  fails that build before rollout, and the image's `cloudflared --version` step fails
  it if the binary doesn't run.
- The pre-commit gate passed: formatting, compiling with warnings as errors, and the
  full default suite. The suite doesn't run the Linux binary or build the image.

## Deploy notes

The image is built at deploy, and a checksum failure stops the deploy before rollout.
After a separately authorized deployment, check:

- The build log shows both base images at `trixie-20261027`, and the
  `cloudflared --version` step prints 2026.10.5.
- `GET /health` returns 200, and a request without a key gets 401.
- An authenticated read-only JSON query works.
- Ingestion continues.
- When `TUNNEL_TOKEN` is set, the connector registers its tunnel connections (in
  the Fly logs), and a read-only request through the Workers VPC path still
  reaches Guardian, ideally one with a large response.

Don't inject test events. Roll back to the previous image if the connector or
Guardian fails to come up.
