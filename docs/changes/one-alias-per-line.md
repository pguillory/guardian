# One alias per line

Every alias gets its own line: `alias Guardian.Counters.Budget` and
`alias Guardian.Counters.Clock`, not `alias Guardian.Counters.{Budget, Clock}`. A
module's full name stays greppable, and adding or removing one alias changes one line.

The 16 grouped aliases (6 in `lib/`, 10 in `test/`, all under rules and counters) were
split in their written order. Each changed file's syntax tree, with metadata stripped,
matches the original's with every grouped alias expanded in place.

Credo's `Credo.Check.Readability.MultiAlias` enforces the rule. `.credo.exs` enables
only that check, in strict mode because the check's priority is low, over the root
`.exs` files, `config/`, `lib/`, `libtest/` and `test/`. The pre-commit hook runs
`mix credo` after the formatting check, and a grouped alias fails the commit. Credo is
a development-only dependency and isn't in the release. The rule is in
CONTRIBUTING.md and the hook's checks in the development guide.

Grouped `import` and `require` aren't checked: Credo has no check that forbids them,
and Guardian has none.

Product spec impact: none. No runtime behavior or architecture changes.

Validation: `mix credo` runs one check over 498 files and reported the 16 grouped
aliases before the split and none after; probes in `lib/`, `libtest/`, `test/`,
`config/` and `.formatter.exs` are reported. The rewritten files' syntax trees match
as above, and the touched tests pass with warnings as errors. The full pre-commit gate
passed (see the commit).
