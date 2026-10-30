# Logging

Status: in progress.

Product spec impact: this first step changes nothing in `docs/product/overview.md` or
`docs/product/spec.md`. Later steps change spec text, recorded here as they land.

## Problem

A passing `mix test` printed hundreds of lines: a `Loading` line per segment file and
an `Expiring` line per expired segment through `IO.puts`, `make: Nothing to be done for
'nifs'` on every compile, Anubis client errors, and crash reports from tests that break
things on purpose. Production printed the same per-segment lines on every boot.

## Rules

CONTRIBUTING.md's "Logging" section, Preston's decision: text logs cover lifecycle
(starting up, loaded, listening, shutting down, stopped), nothing per event, segment or
request; an error-level line is a bug or problem to fix; logs get clean by fixing
errors, never by hiding them; logs are not scrubbed, except that each router drops the
API key once it passes; everything goes through Logger.

## Changes

1. Lifecycle through Logger. Guardian logs "Guardian: starting build …", "Guardian:
   stopping" and "Guardian: stopped" at info. Storage's initial load logs "Storage:
   loading N segment files" before it starts, since a large data directory can take a
   while, and "Storage: loaded N segments (M skipped)" when done; the per-file `Loading`
   line goes, and rescans log only files they skip. The startup notice about `.seg`
   files with unparseable names becomes a Logger warning, still once per start. The
   per-segment `Expiring` line goes with no replacement, so expiry leaves no text trace.
   Bandit's own startup line says the web server is listening. The `nifs` make target
   gets an empty recipe, so an up-to-date build prints nothing.

## Validation

`mix compile` on an up-to-date build prints nothing; the storage suite passes without
the per-segment lines.
