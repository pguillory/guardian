# Contributing

Thanks for your interest in Guardian.

## Setup and checks

[docs/guides/development.md](docs/guides/development.md) has the prerequisites, the
setup (`mix deps.get`, `bin/install-git-hooks`), the checks the pre-commit hook runs
at every commit, and how to run Guardian locally.

## Changes

- Before editing a file under `lib/`, read every existing `AGENTS.md` from `lib/`
  down to the file's directory. Those files record each subsystem's rules for
  human and AI contributors alike. AGENTS.md is the canonical real instruction
  file at every level. Codex loads only the path to its starting directory, so
  explicitly read applicable descendant instructions before editing.
- User-visible behavior is specified in [docs/product](docs/product). The design is in
  [docs/architecture](docs/architecture). Update them in the same change when behavior
  or structure changes.
- Keep the ingestion path free of external service calls, and keep tests free of
  external services.
- Add a test with every behavior change, and run the default suite (`mix test`)
  before sending a change.

## Elixir style

Always write function and macro definitions with `do...end` blocks, including
`def`, `defp`, `defmacro`, `defmacrop`, and `defn`-style variants. Do not use the
keyword body form (`def example(value), do: value`), even for a single expression.
Keyword-form `if`, `case`, and `unless` expressions are fine.

Private function names should say what the function does, as much as public ones.

The normal test suite checks this rule in `lib/`, `libtest/`, and `test/`, including
definitions inside quoted code. Declarations without bodies and `defdelegate` are
unaffected.

Define one module per file under `lib/` and `libtest/`, at the path matching its
name, including exceptions and structs that belong to another module
(`Guardian.AST.ParseError` lives in `lib/guardian/ast/parse_error.ex`).
A `defimpl` stays in the file of the protocol or struct it implements; the vendored
DistributedStream `Enumerable` implementation keeps its own file. The same scan test
checks that each file defines at most one module, counting nested `defmodule` and
`defprotocol` but not quoted code or `defimpl`.
Test files may still define small support modules inline.

Give every alias its own line: `alias Guardian.Counters.Budget` and
`alias Guardian.Counters.Clock`, never `alias Guardian.Counters.{Budget, Clock}`. Each
module's full name stays greppable, and adding or removing one alias is a one-line
diff. Credo's `MultiAlias` check enforces this in the pre-commit hook (`mix credo`);
`.credo.exs` enables only that check. Grouped `import` and `require` aren't checked,
and Guardian has none.

A test file `import`s the module it tests and calls its functions unqualified
(`import Guardian.Lists`, then `flatten(list)`), rather than aliasing it and writing
`Lists.flatten(list)`. Stay qualified, and keep the alias, where an import would be
ambiguous: a function that collides with `Kernel` or with a test helper, or a test that
covers several modules. A struct or module name used as a value (`%Event{}`, a
supervisor child) still needs its alias, alongside the import. Nothing checks this;
follow it in new tests and when you edit old ones.

## Exception handling

A `try`, `rescue` or `catch` is rare, and each one has a comment naming its reason.

Expected outcomes are data, not exceptions. That means validation failures, and parse
errors: the handwritten parser returns `{:error, %Guardian.AST.ParseError{}}` and never
raises for bad input. Anything else raises, and these are what callers then see:

1. Request handlers: a 500, from the framework. The JSON API's `Plug.ErrorHandler` only
   gives the response its body.
2. Queries: the query fails whole. MCP calls: the call fails.
3. Segments: an unexpected insert failure crashes the segment. Acknowledged rows lost
   that way are accepted, and listed in the known limitations.
4. Rules: a crash gives a 500. Counter updates already made stay.
5. Shutdown: new queries are refused, best effort and with no lock, so an unlucky running
   query fails.

Reasons that justify a catch:

1. Value semantics: an arithmetic exception such as float overflow becomes null, caught
   by name (`:error, :badarith`).
2. Advisory and fail-open by spec: a counter store that is merely unreachable. Name what
   unreachable means, so a bug still crashes.
3. Answers that outlive a failure: recording a query's outcome and reraising, or a write
   to a built-in table that must not fail its caller.
4. Bad input from a library that raises on it, or an external system's garbage response.
5. Crossing a process boundary: relaying a failure to the caller that is waiting on it.
6. Isolation: one failure that would otherwise take down far more than itself, such as a
   stored rule file tripping a bug on every node at once.

Keeping values out of logs is not a reason. Logs may hold what a failing process held;
only the admin key and `RELEASE_COOKIE` must never reach a log line. A test that exists
only to check a removed catch goes with it.

## Testing philosophy

This is the direction for new tests. Many existing tests predate it and are being
brought in line a category at a time, so don't read the suite as a counterexample.

Tests are async by default. A module is `async: false` only when it truly can't be
made async, and then it names its one reason (see "Test isolation").

The bulk of tests use the primitives users have: create or modify a rule, store
events, run a query, and check responses and results. They're clean and async, each on
its own table, and tests that pick different table names can't interfere. The MCP and
HTTP layers are thin wrappers over those primitives, so network tests are minimal: per
MCP tool and API call, one success and one error. Storage and Counters.Store are
tested at their module boundaries, through their public functions. Any module with
clean functions gets plenty of plain unit tests.

Tests don't peek inside or touch processes; they don't kill, freeze or break internals;
no timeout tests; no sleeps.

Tests don't count resources across the whole VM: processes, ports, mappings, memory,
open files, ETS tables, binaries. Where a specific operation promises cleanup, test
that promise directly at the boundary: get the segment's file name, assert the file
exists, delete the segment, assert the file is gone. Global leaks are watched in
production through `system_stats`, which records memory, process, port and ETS counts,
open file descriptors, segment-file mappings, native columns and resident memory: a
number rising over time reveals a leak.

The built-in tables `queries`, `query_parse_errors`, `web_requests` and
`web_responses` are records for ad hoc analysis. Tests don't check what they hold or
that a write to them happens. (`system_stats`, the leak watch above, stays tested.)

Peer VM tests are tagged `:cluster` and excluded by default. Promises that need a
server to stop and start, such as a clean shutdown or a restart keeping acknowledged
rows, are tagged `:lifecycle`: a slow synchronous suite, also excluded by default. Today it
stops and restarts Storage on a peer, calls the stop callback and restarts the rule
server in the test VM, for its startup tests (`docs/changes/rules-startup-lifecycle.md`);
it doesn't boot a whole application. Segment
handoffs, retirement and persistence scheduling aren't in the suite: an agent checks by
hand (insert, stop, start, query) only when a change touches segment lifetimes or
persistence.

Run `mix test --include cluster --include lifecycle` before every deploy. With no CI
and the pre-commit hook on the default run, that is what keeps those tests from
rotting unseen.

A passing run should be simple and fast.

## Logging

1. Text logs cover lifecycle: starting up, loaded, listening, shutting down, stopped.
   Nothing per event, per segment or per request.
2. Error-level logs mean one thing: a bug or problem we need to fix. Anything there is
   work to do. Crashes go to the log through Erlang/Elixir's built-in handlers; leave
   those on and let them show.
3. Logs get clean by fixing errors, never by hiding them: no `capture_log`, log filters
   or global silencing to quiet output, and no `errors` table. A process crashing in
   normal or test operation is a bug: fix it, or if a test causes it on purpose, the
   test goes.
4. Don't scrub logs or crash reports, and don't test what a log line leaves out.
   Each router drops the `x-api-key` header once the key passes, so no plug or
   handler after it holds the key; that is about the conn, not the log. Bandit's own
   conn still has the header, attached as metadata to its error lines, which the
   default formatter doesn't print.
5. Everything goes through Logger, not `IO.puts`. The one exception is the random admin
   key a dev Mix run generates (`config/runtime.exs`), printed to stderr because Logger
   isn't running yet at config time.

Production logs at info, so lifecycle lines show there. Tests run at warning, so a
passing `mix test` prints only dots and the summary.

## Test isolation

Tests assume every table starts empty, and each test uses its own table. The test run
gets a fresh data directory, so no test needs to delete or truncate a table before it
starts, and a table that stays behind after a test cannot affect another one. Name each
test's tables uniquely per invocation (`"orders_#{System.unique_integer([:positive])}"`),
because repeated passes (`--repeat-until-failure`) share one VM and data directory.
That is also what lets tests run concurrently: mark the module `async: true`.

The principle is that things that don't need to interfere shouldn't. This is about
robustness and the ability to scale the suite, not multi-tenancy: Guardian has no
tenants. Rely on the system's own isolation (storage, rules and queries are per table)
instead of mocks and explicit cleanup. Delete a table only when it holds so much
that leaving it would slow later tests.

Isolation stops at the all-table schema read. SHOW TABLES, DESC and the `schema` table
ask every registered mutable segment for its schema and fail after 5 s without an
answer, so a fake segment in an async test must answer `:schema` promptly, as
`Guardian.Test.Segments.intercept_append/2`'s does, or be a dead PID.

Every module is `async: true` unless it touches something shared by the whole VM that
can't be avoided: a connected peer node, the `:lifecycle` suite's
stops (a VM-wide stopping flag, a peer), node-wide counter budgets, the rule server's
store and published map, log capture that must see only its own events, or an
application env setting the code reads instead of taking it as an argument (being
retired: pass the setting to the function it applies to). Say which in a
one-line comment above `use ExUnit.Case`. Suspending, restarting or scanning
application processes is not a reason: such tests go (see "Testing philosophy").

Put new shared test infrastructure under `Guardian.Test.*` in
`libtest/guardian/test/`, split by concern. Reuse what is there instead of writing a
local copy: `Guardian.Test.Polling` for any wait (no sleep loops),
`Guardian.Test.Tables.unique_table/1` for table names, `Guardian.Test.Cluster` for
peers, and `Guardian.Test.Counters.Budget.healthy/2` for counter tests of results
(options and a batch that match, since a default batch caps every call at 250 ms); see the
[test support namespace](docs/changes/test-support-namespace.md) for existing helpers
and their concurrency requirements.

Generic mechanisms belong in generic layers, not inside a feature module (for example,
an object-store lock would be a generic lock-on-a-key in the S3/R2 client, not part of
Rules).

By contributing, you agree that your contributions are licensed under the MIT license
of this repository.
