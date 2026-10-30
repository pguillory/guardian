# Exception policy

Status: done.

Product spec impact: `docs/product/spec.md` changes in section 3 item 4 (`/health`),
4.1, 4.2 items 1 and 5, 4.3, 4.4, 4.5 (the note on diagnostics), 5 items 6 and 9, 5.1.3
item 5, 5.1.4 item 5, 7, 8 (`error_kind`, `error`) and 12 (new item 8). The overview is
unchanged.

## Problem

Guardian had grown catches around most of its paths: to keep values out of logs, to turn
any failure into a per-event error, or to fail a counter open on any failure at all. They
hid bugs and had to be kept in step with one another.

## Policy

CONTRIBUTING.md, "Exception handling". A catch is rare and each one has a comment naming
its reason. Expected outcomes are data: validation failures and parse errors. Anything
else raises: request handlers give a 500, queries fail whole, MCP calls fail, segments
crash, rule crashes give a 500 with partial counters accepted. Arithmetic exceptions
that become null are caught by name. New queries are refused at shutdown, best effort.
Logs are not scrubbed; only the admin key and `RELEASE_COOKIE` must never reach a line.

## Changes

1. Parser: every parse and tokenize function returns `{:ok, result}` or
   `{:error, %Guardian.AST.ParseError{}}`. `ParseError` is a plain struct. Its internal
   throws stay, as control flow stopped at one catch in `with_source_parsed/2`.
   `Guardian.Query.execute/1` (no options) returns the struct; `Guardian.Web.Query`
   records it and answers with its message.
2. Ingest: Engine, Runner and Runtime catch nothing. A raising rule crashes its worker and
   Runner exits with its reason, except `:killed`, which is the heap limit and stays a
   per-event outcome. `Guardian.Rules.Runtime.Failure` is gone, and so are the "Rule X line
   N failed" log line and its once-a-minute table: the sender gets the error.
3. Counters: Execution, Machine, Store and Transport lose their catches. Fail-open stays
   for an unreachable store, named: Transport's `invoke` (erpc timeout, erpc failure, the
   owner going down mid-call, an owner without the endpoint), and Store's table-gone
   checks. A raise inside the worker relays as an exit through the guard.
4. Web: the JSON API uses `Plug.ErrorHandler` for its documented bodies, and reraises, so
   Bandit logs a 5xx and closes the connection. The MCP `query` tool's rescue is gone, so
   an unexpected raise is JSON-RPC -32603. `Guardian.Cluster.NodeError` becomes
   `Guardian.Query.Error`, same message.
5. Scrub-only catches: `Rules.Server.scrubbed`, `Counters.Store.scrubbed`, `S3.safely` and
   most of `Guardian.Failure`. `S3.parse_list` treats a garbage listing as data.
6. Shutdown: `Guardian.Application.prep_stop/1` sets a `:persistent_term` flag
   (`Application.put_env` there deadlocks with the application controller);
   `Guardian.Storage.ready?/0` answers false and `Guardian.Query.execute/1` refuses.

## Surviving catches

Each has a comment in place.

1. Value semantics, by name: arithmetic operators, avg, sum, moments, exp, power,
   cosine_similarity.
2. Value parsing: tokenizer numbers, url `system_limit`, regex invalid UTF-8 subject, S3
   date, unstorable constants becoming null.
3. Control flow: `Parser.with_source_parsed/2`.
4. Crossing processes: `Guardian.Query`'s process boundary, `WorkerErrors.guard/2`, the
   regex helper, `Guardian.Detached`.
5. Raised errors to data: `Guardian.Query`'s `Query.Error` rescues.
6. Added context: Executor's `rows_to_columns`.
7. Keep the answer: `Web.Query` (records, reraises), `QueryLog`, `QueryParseErrors`,
   `Engine.try_log_event/2`, `IngestIdempotency`.
8. Storage: segment retire, read and append (a gone segment is expected), persisted
   segments' pack and store, `SegmentFile` read.
9. Counters: Budget, Store's descriptor, execute_one and increment table checks,
   Transport's `invoke`, Restarter's isolation.
10. External input: the MCP router's rescue of the library validator, and `S3.parse_list`'s
    catch of xmerl's fatal exit.
11. `Rules.Server.write/3`: timeout (unknown outcome) and noproc only.
12. `Rules.Compiler` and `RuleSet.parse_source`, the one deviation from the first plan.
    Every node polls the same store, so a bug tripped by one stored file would crash
    `Rules.Server` past its restart limit on every node and refuse boot. These turn it
    into invalid rules instead.

## Follow-ups

1. Convert the Resolver from raising `Query.Error` to returning it, which removes
   `Guardian.Query`'s rescues.
