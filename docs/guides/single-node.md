# Running a single node

## Docker

Supported architecture: linux/amd64; arm64 is untested (details in
[system.md 10.1](../architecture/system.md#101-build)).

```sh
docker build -t guardian .

export GUARDIAN_ADMIN_API_KEY="$(openssl rand -hex 32)"
export GUARDIAN_INGEST_API_KEY="$(openssl rand -hex 32)"

docker run -d --name guardian \
  --stop-timeout 120 \
  -p 127.0.0.1:8080:8080 \
  -v guardian_data:/data \
  -e GUARDIAN_ADMIN_API_KEY \
  -e GUARDIAN_INGEST_API_KEY \
  guardian
```

To build an amd64 image on Apple Silicon (`--platform linux/amd64`), note that amd64
runs under emulation there, where the BEAM JIT miscompiles Mix projects. Add `--build-arg ERL_FLAGS="+JMsingle true"` to `docker build` and
`-e ERL_FLAGS="+JMsingle true"` to `docker run`.

`--stop-timeout 120` gives Guardian time to persist its in-memory segments when the
container stops (its shutdown budget is about 110 s; Docker's default is 10 s).
Mount a volume at `/data`, or segments land in the container's writable layer and are
lost with it. The server answers `/health` only after loading every segment on its
volume, so the first check after a restart can take a while on a large volume.

```sh
curl http://127.0.0.1:8080/health

curl -s http://127.0.0.1:8080/api/json/send_events \
  -H "x-api-key: $GUARDIAN_INGEST_API_KEY" -H 'content-type: application/json' \
  -d '{"table": "requests", "events": [{"path": "/", "status": 200, "timestamp": "2026-10-22 12:00:00"}]}'
```

The ingest key can only send events. Queries go through MCP at
`http://127.0.0.1:8080/mcp` with the admin key, for example from Claude Code:

```sh
claude mcp add --transport http guardian http://127.0.0.1:8080/mcp \
  --header "x-api-key: $GUARDIAN_ADMIN_API_KEY"
```

## TLS

Guardian speaks plain HTTP. Put TLS in front of it (a reverse proxy, a load balancer, or
Fly's edge) before you expose it beyond the machine; a key travels in every
request.

## The operator's console

```sh
docker exec -it guardian /app/bin/guardian remote
```

Inside it, `Guardian.Query.execute("SHOW TABLES")` returns `{:ok, columns, rows}` or
`{:error, message}`. Queries called directly from IEx are not recorded in `queries`.

## Erlang distribution

With neither `GUARDIAN_NODE_HOST` nor `FLY_PRIVATE_IP` set, the node is named
`guardian@localhost` and Erlang distribution (epmd and the distribution port) listens
only on loopback. `bin/guardian remote` works on the machine itself, and nothing else
can reach distribution. No cookie is needed.

To run more than one node, see [a cluster on any machines](cluster.md) or
[Fly.io](fly.md). Every setting is in the
[configuration reference](../reference/configuration.md).
