# query-tidy: Query-layer follow-ups

Status: implemented.

Four small follow-ups left by the October 18 Query reviews, checked against the code
on October 27 and done together. None changes what a query, an ingest, the JSON API
or the MCP tool returns.

## Problem

1. Query had no declared public boundary, unlike Storage, and several of its modules
   had neither a moduledoc nor `@moduledoc false`.
2. `Guardian.Aggregation.Ordering` reached into a Query internal,
   `Guardian.Query.Sorting.merge_take/4`, for a generic merge of two ordered lists.
3. `Guardian.Query.labels/1` and the SHOW/DESC clauses of
   `Guardian.Query.Resolver.labels/1` were reachable only from tests, because the
   Resolver rewrites SHOW and DESC to SELECTs before labelling (TODO
   `test-only-labels`).
4. No test covered a consumer that exits normally in the middle of a pipeline, and
   five test call sites spelled out the list of a query's process modules.

## Behavior after the change

1. `lib/guardian/query/CLAUDE.md` has a "Public boundary" section in three tiers:
   what the rest of Guardian may call, what the AST may also call, and what is
   internal. Planner, Sorting and VirtualTable.Schema are `@moduledoc false`;
   Function, Constant and ColumnOrConstant have moduledocs. The function modules are
   documented together by the registry and `function/CLAUDE.md`.
2. `merge_take/4` lives in the leaf `Guardian.Lists`, unchanged; Sorting and
   Ordering call it there.
3. `Guardian.Query.labels/1` is gone, and `Resolver.labels` is private and handles
   only SELECT. Labels are tested through `Guardian.Query.Resolver.resolve/1`, SHOW
   TABLES and DESC included. Labels the API returns are unchanged.
4. A failures test covers a consumer that suspends its enumeration and, once a
   worker is known to be blocked, returns normally: the pipeline must leave no
   process behind. Changing the routers' `{:shutdown, :consumer_exited}` to a normal
   exit leaves four pipeline processes running and fails it.
   `Guardian.Test.Query.query_modules/0` names a query's process modules for the
   tests that wait on them.

Considered and dropped, as of October 27:

- One shared name/arity registry helper for Query.Function and Aggregation: each is
  now three lines, and they key differently (by name and arity, and by name).
- Renaming `Guardian.Aggregation.Ordering`: its moduledoc already states its scope.
- Renaming Storage's `append_flattened*` to `append_flat*`: optional, and no
  confusion has been reported.
- A test that `Guardian.Query.Failure.from_exit/1` has a clause for every tagged
  pipeline failure reason: its tests already name every reason, and an unlisted one
  gets a bounded generic message.
- An end-to-end `:unexpected_sender` test: only a forged message triggers it, and its
  message is unit-tested.
- Tokens carrying byte offsets so parse errors need not re-tokenize: only the error
  path re-tokenizes, and the change would reshape tokens throughout the parser.
- A shared authenticated-request test helper: `Guardian.Test.JsonApiClient` exists,
  and the remaining hand-built requests vary the key and headers on purpose.

Follow-up: `resolver-test-only-functions` in TODO.md.

## Product spec impact

None.

## Validation

Focused runs of the touched test files, a mutation check of the new pipeline test,
and the full suite through the pre-commit hook.
