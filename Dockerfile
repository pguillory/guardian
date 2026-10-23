# syntax=docker/dockerfile:1
# ADD --checksum needs Dockerfile frontend 1.6 or later; the line above selects it.
# Guardian release image for Fly.io. See the "Fly.io" section of README.md.
#
# Build locally with:
#   docker build --platform linux/amd64 --build-arg GIT_COMMIT=$(git rev-parse HEAD) .
#
# On an arm64 host (Apple Silicon), amd64 builds run under emulation, where the BEAM
# JIT miscompiles Mix projects. Add --build-arg ERL_FLAGS="+JMsingle true" there, and
# pass -e ERL_FLAGS="+JMsingle true" to docker run. Fly's builders are native amd64.

ARG ELIXIR_VERSION=1.19.6
ARG OTP_VERSION=28.5.0.8
ARG DEBIAN_VERSION=trixie-20261020-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

# build-essential for the NIFs (src/column.c, src/mmap.c) and the jq worker
# (src/jq_worker.c); headers and libraries for the hyperscan NIF and the jq worker.
RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential git libhyperscan-dev libjq-dev \
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
    ca-certificates libhyperscan5 libjq1 libssl3t64 libstdc++6 \
  && rm -rf /var/lib/apt/lists/*

# cloudflared, for the optional outbound Cloudflare Tunnel connector (bin/fly-start)
# that lets Cloudflare Workers reach Guardian through Workers VPC. Pinned and checksummed: the build
# fails if the download doesn't match. ADD checks the hash and sets the mode itself, so
# the binary lands in one layer. The version and hash are written here, not as build
# args, so they change together: a bump edits both lines.
ADD --checksum=sha256:3bfc539f45d2620c71debb7a86be0efa737ed5ccbad9eb85c787116900e5c586 \
  --chmod=0755 \
  https://github.com/cloudflare/cloudflared/releases/download/2026.10.1/cloudflared-linux-amd64 \
  /usr/local/bin/cloudflared
RUN /usr/local/bin/cloudflared --version

ENV LANG=C.UTF-8
# Fly mounts the guardian_data volume here. With plain `docker run`, mount a volume
# (-v guardian_data:/data) or segments land in the container's writable layer.
ENV GUARDIAN_DATA_DIR=/data

WORKDIR /app
COPY --from=builder /app/_build/prod/rel/guardian ./
COPY bin/fly-start /app/fly-start

# Prove the jq() sandbox on this exact image (kernel features, glibc, libjq,
# oniguruma): empty environment, seccomp denying files, jq builtins working under the
# filter, and the memory limit ending the worker. The build fails otherwise.
RUN env -i /app/lib/guardian-0.1.0/priv/jq_worker --self-test

# Runs as root: Fly volumes mount root-owned, and each Fly Machine is its own VM whose
# only workload is Guardian.
EXPOSE 8080
# bin/fly-start runs `guardian start`, plus the tunnel connector when TUNNEL_TOKEN is set.
CMD ["/app/fly-start"]
