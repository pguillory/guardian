# No function-valued test options

## Problem

The follow-up to `docs/changes/clock-as-data.md`. Three test seams were still function
parameters: QueryParseErrors' and QueryLog's `:writer`, and
`Guardian.Web.Query.execute/3`'s `:execute`. The rule: no function-parameter injection
for test seams. If a fake is needed, swap it at module level, as Transport's
compile-time `store_backend` does.

## Behavior after the change

None for callers or operators: no wire, storage or row change. The recorders always
write through `Guardian.Engine.try_log_event/2`, and `Guardian.Web.Query.execute/3`
always calls `Guardian.Query.execute/2` in a release. The options are gone, not
ignored.

## Tests

- Recorder write failures use the real path. A test hands off the built-in table's
  mutable segments (`Guardian.Test.Segments.hand_off_mutable_segments/1`), so that
  `intercept_append/2`'s one-call fake is the only choice for the next append, and the
  fake refuses it. Engine's real failure then reaches the recorder, so the logged kind
  is `ArgumentError`, where the fake writer returned a made-up `RuntimeError`.
- QueryLog's backlog test counts the rows really stored in `queries` (1,001), instead
  of messages from a writer. It now makes about 2,000 real writes.
- Exits, throws and a non-exception `:error` can't be provoked through
  `Guardian.Query.execute/2`, which turns failures inside a query into
  `Guardian.Query.Error`, so the "reraised unchanged" test needs a fake. `config.exs`
  gives the test build `Guardian.Test.Web.QueryBackend` as `Guardian.Web.Query`'s
  `query_backend`. It passes through unless the calling process asked for one failure
  (`fail_next/3`), and releases compile to a direct `Guardian.Query` call.

No test coverage is lost. Test builds' `Guardian.Web.Query` calls go through one extra
pass-through function.

## Product spec impact

None in `docs/product/overview.md` or `docs/product/spec.md`. Security architecture:
none.

## Rolling deploy

No storage or message change.
