# Third-party notices

Guardian itself is licensed under the MIT license (see [LICENSE](LICENSE)). It is built
from, and its release image contains, the third-party components below, each under its
own license. Those licenses apply to those components, not to Guardian's own code.

## Hex dependencies

Fetched by Mix at build time, at the versions pinned in `mix.lock`, and compiled into
the release. Licenses are as each package declares them on Hex.

| Package | Version | License | Used in |
| --- | --- | --- | --- |
| anubis_mcp | 0.16.0 | LGPL-3.0 | release |
| bandit | 1.13.1 | MIT | release |
| cors_plug | 3.0.3 | Apache-2.0 | release |
| dns_cluster | 0.3.1 | MIT | release |
| elixir_make | 0.10.0 | Apache-2.0 | build |
| finch | 0.24.0 | MIT | release |
| hpax | 1.1.0 | Apache-2.0 | release |
| hyperscan | 0.1.5 | MIT | release |
| hypex | 1.1.1 | MIT | release |
| jason | 1.4.5 | Apache-2.0 | release |
| mime | 2.0.7 | Apache-2.0 | release |
| mint | 1.11.0 | Apache-2.0 | release |
| nimble_options | 1.1.1 | Apache-2.0 | release |
| nimble_pool | 1.1.0 | Apache-2.0 | release |
| peri | 0.6.2 | MIT | release |
| plug | 1.20.3 | Apache-2.0 | release |
| plug_crypto | 2.2.0 | Apache-2.0 | release |
| superlist | 0.1.5 | MIT | release |
| telemetry | 1.4.2 | Apache-2.0 | release |
| thousand_island | 1.6.0 | MIT | release |
| uuid | 1.1.8 | Apache-2.0 | release |
| websock | 0.5.3 | MIT | release |
| benchee, deep_merge, statistex | 1.5.1, 1.0.2, 1.1.1 | MIT | development only |
| exsync, file_system | 0.4.1, 1.1.1 | BSD-3-Clause, Apache-2.0 | development only |
| freedom_formatter | 2.1.3 | Apache-2.0 | development only |

### anubis_mcp (LGPL-3.0)

Guardian uses anubis_mcp, the MCP server library, unmodified as a Hex dependency. Its
source is published at https://hex.pm/packages/anubis_mcp (version 0.16.0) and
https://github.com/zoedsoupe/anubis-mcp. A release or image built from this repository
contains anubis_mcp's compiled modules. Under the LGPL you may replace them with a
modified version: change the dependency in `mix.exs`/`mix.lock` (or point it at your
own copy) and rebuild the release with `mix release` or `docker build`. The full
license text ships with the package (`deps/anubis_mcp` after `mix deps.get`) and is
at https://www.gnu.org/licenses/lgpl-3.0.html.

## Vendored code

1. `lib/query/distributed_stream.ex`: vendored and changed from distributed_stream
   0.1.4 (https://github.com/pguillory/distributed_stream) by Preston Guillory, MIT
   license. Its notice is kept in `lib/query/distributed_stream/LICENSE`.
2. `src/mmap.c`: Guardian's read-only mmap NIF. It replaces the mmap 0.1.1 Hex package
   (https://github.com/pguillory/elixir-mmap, MIT, by the same author), with fixes to
   its resource and file-descriptor handling.

## System libraries and tools

Not distributed in this repository. They are installed from Debian packages into the
release image (or from your OS for development) and linked at build time:

| Component | License | Used by |
| --- | --- | --- |
| Hyperscan (`libhyperscan5`) | BSD-3-Clause | the hyperscan NIF (regular expressions) |
| jq (`libjq1`) with Oniguruma (`libonig5`) | MIT, BSD-2-Clause | the sandboxed jq worker (`src/jq_worker.c`) |
| Erlang/OTP | Apache-2.0 | the runtime, bundled into the release |
| Elixir | Apache-2.0 | the standard library, bundled into the release |
| OpenSSL (`libssl3t64`) | Apache-2.0 | the runtime's crypto |

The image also downloads cloudflared 2026.10.1 (https://github.com/cloudflare/cloudflared,
Apache-2.0), pinned by checksum, for the optional Cloudflare Tunnel connector.
