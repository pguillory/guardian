# Guardian Architecture

This file is the index of Guardian's design documents. It holds no design of its own,
so there is one place for each topic.

1. [docs/architecture/system.md](docs/architecture/system.md): how the system is built.
   Supervision tree, ingest path, storage engine (segments, persistence, mmap,
   retention), query engine (parsing, planning, distributed execution, regular expressions),
   the JSON and MCP interfaces, clustering, configuration, deployment, testing, and
   known limits.
2. [docs/architecture/security.md](docs/architecture/security.md): trust boundaries,
   the invariants each relies on, and the gaps.
3. [docs/product/overview.md](docs/product/overview.md) and
   [docs/product/spec.md](docs/product/spec.md): what Guardian does, as callers see it.
4. `docs/guides/` and `docs/reference/`: how to build, run, configure, and call
   Guardian, and its known limitations. The README links each page.
5. The `CLAUDE.md` file in each `lib/` directory: rules for changing that subsystem.
6. [TODO.md](TODO.md) and `docs/changes/`: planned work, known gaps, and the design of
   each change.
7. [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md): third-party components and their
   licenses; the reasons some dependency versions are held are in system.md.
