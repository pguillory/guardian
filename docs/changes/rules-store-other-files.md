# Misplaced rule files are errors of no table

Status: implemented.

## Problem

Reading the rule store had code for states only a hand edit of the store could make,
which the tests no longer plant (`rules-in-process.md`, Tests item 4) and which is not
supported: a `.gsql` key at an invalid path was not fetched but loaded with an empty
source; an object over 64 KiB was not fetched but loaded as a `:too_large` sentinel;
and a bad path was attributed to the table its first folder named, which made that
table invalid.

## Behavior after the change

Preston's call: remove that code, where it serves nothing else. A `.gsql` key at any
other path than `<table>/<name>.gsql` is fetched like any rule file and is a path error
that belongs to no table: every write's reply lists it, no table's events fail for it,
and as a pre-existing error it never blocks a write. An oversized rule file is still
an error for its table, now after a full fetch.

Kept:

1. The listing still skips every key not ending in `.gsql`. Besides planted files, it
   keeps the write lock, S3 console folder markers and unrelated objects under a
   shared prefix out of the read, so one of them that can't be fetched can't block
   startup or every write, and its contents never reach Rules.Server's state (which
   crash reports show).
2. `Rules.Server`'s `:reload` error reply. Store failures reach it, and since the lock
   is released at the save (`rules-module-per-table.md`), so does a node whose pre-load
   purge fails at the reload; the writer names that node as unconfirmed from it.

## Product spec impact

`docs/product/spec.md` 5.1.1 item 3: "a `.gsql` file at any other path is a validation
error, for the table its first folder names if that is a valid table." becomes "a
`.gsql` file at any other path is a validation error that belongs to no table: every
write's reply lists it, and no table's events fail for it."

## Docs and tests

`docs/guides/rules.md` (local folder), `docs/architecture/system.md` (Rules, loading),
`lib/guardian/rules/AGENTS.md` (Server). `rule_set_test.exs`: a misnamed file leaves
its folder's table valid, with an error of no table; `RuleSet.parse_key/1` now calls
any key not ending in `.gsql` a path error (Server never passes one).
