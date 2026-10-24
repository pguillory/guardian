# syntax=docker/dockerfile:1
# ADD --checksum needs Dockerfile frontend 1.6 or later; the line above selects it.
# Guardian release image. See docs/guides/fly.md. CI builds
# linux/amd64; linux/arm64 has a cloudflared stage and no x86-only dependency, but is
# not yet tested.
#
# Build locally, for the host's own architecture, with:
#   docker build --build-arg GIT_COMMIT=$(git rev-parse HEAD) .
#
# Cross-building amd64 on an arm64 host (Apple Silicon, with --platform linux/amd64)
# runs under emulation, where the BEAM JIT miscompiles Mix projects. Add
# --build-arg ERL_FLAGS="+JMsingle true" there, and pass -e ERL_FLAGS="+JMsingle true"
# to docker run. Fly's builders are native amd64.

ARG ELIXIR_VERSION=1.19.6
ARG OTP_VERSION=28.5.0.8
ARG DEBIAN_VERSION=trixie-20261020-slim

# Set by BuildKit for the target platform: selects the cloudflared stage below.
ARG TARGETARCH
ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

# cloudflared, for the optional outbound Cloudflare Tunnel connector (bin/fly-start)
# that lets Cloudflare Workers reach Guardian through Workers VPC. One stage per
# architecture, each pinned and checksummed: the build fails if a download doesn't
# match, and an architecture without a stage fails to build. ADD checks the hash and
# sets the mode itself. The version and hashes are written here, not as build args, so
# they change together: a bump edits all of these lines.
FROM scratch AS cloudflared-amd64
ADD --checksum=sha256:3bfc539f45d2620c71debb7a86be0efa737ed5ccbad9eb85c787116900e5c586 \
  --chmod=0755 \
  https://github.com/cloudflare/cloudflared/releases/download/2026.10.1/cloudflared-linux-amd64 \
  /cloudflared

FROM scratch AS cloudflared-arm64
ADD --checksum=sha256:2c65dfabf616c40efc7545d107d7a57ad5e21377e2964b7e88af19a238074a46 \
  --chmod=0755 \
  https://github.com/cloudflare/cloudflared/releases/download/2026.10.1/cloudflared-linux-arm64 \
  /cloudflared

FROM cloudflared-${TARGETARCH} AS cloudflared

FROM ${BUILDER_IMAGE} AS builder

# build-essential for the NIFs (src/column.c, src/mmap.c).
RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential git \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
ENV MIX_ENV=prod
ARG ERL_FLAGS=""
ENV ERL_FLAGS=${ERL_FLAGS}

RUN mix local.hex --force && mix local.rebar --force

# Dependencies first so they are cached across source-only changes.
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mkdir config
COPY config/config.exs config/
RUN mix deps.compile

COPY Makefile ./
COPY src src
COPY priv priv
COPY lib lib
COPY config/runtime.exs config/
COPY rel rel

# Build.commit/0 reads priv/commit at compile time, so write it before compiling.
ARG GIT_COMMIT=unknown
RUN printf '%s\n' "$GIT_COMMIT" > priv/commit

RUN mix compile && mix release

FROM ${RUNNER_IMAGE}

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates libssl3t64 libstdc++6 \
  && rm -rf /var/lib/apt/lists/*

COPY --from=cloudflared /cloudflared /usr/local/bin/cloudflared
RUN /usr/local/bin/cloudflared --version

ENV LANG=C.UTF-8
# Fly mounts the guardian_data volume here. With plain `docker run`, mount a volume
# (-v guardian_data:/data) or segments land in the container's writable layer.
ENV GUARDIAN_DATA_DIR=/data

WORKDIR /app
COPY --from=builder /app/_build/prod/rel/guardian ./
COPY bin/fly-start /app/fly-start

# Runs as root: Fly volumes mount root-owned, and each Fly Machine is its own VM whose
# only workload is Guardian.
EXPOSE 8080
# bin/fly-start runs `guardian start`, plus the tunnel connector when TUNNEL_TOKEN is set
# (unless GUARDIAN_TUNNEL=off).
CMD ["/app/fly-start"]
