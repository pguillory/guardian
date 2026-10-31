# Rules startup tests in the lifecycle suite

Status: implemented.

Product spec impact: none. No statements change in `docs/product/overview.md` or
`docs/product/spec.md`. Only test tags and notes for contributors change.

## Decision

Preston's: the Rules.Server tests that are about startup belong to the `:lifecycle`
suite, which `mix test` excludes and `mix test --include cluster --include lifecycle`
runs before every deploy. The test is "a startup promise", not "a slow test"; the move is
not claimed as a speed gain.

## What moved

Tagged `:lifecycle` in place (no code moved or rewritten):

1. `server_test.exs`: an invalid stored table fails at boot by default, other tables load.
2. `server_test.exs`: invalid counter rules at boot invalidate only their table.
3. `server_test.exs`: a misconfigured store refuses startup at once.
4. `counter_reload_test.exs`: boot and reload publish the same result for the same
   invalid files.

Already tagged: an unreachable store at boot is retried until it answers; a rate-limited
store at boot is retried.

## What stayed

Most other tests that restart the server do so only to reach the fake store; those are
untouched, and Preston hasn't decided them. Three tests mix reload or a local store with
boot and stay in the normal run; they are listed for Preston: "a local folder is read like
a bucket: stray files are ignored, misplaced rules are errors", "a reload that finds a
table's stored copy invalid fails its events, like boot" and "a misnamed rule file makes
its table invalid instead of dropping its rules".

## Coverage shift

The `:lifecycle` run is a manual step before a deploy (CONTRIBUTING.md); the pre-commit
hook runs only the default suite. In the default run:

1. Stays: a plain invalid table at boot with a good table loading beside it (the three
   tests above).
2. Leaves: the refused startup of a misconfigured store, counter-rule invalidity at boot,
   and boot and reload equivalence for counter dependencies, including a transitive
   reader.
