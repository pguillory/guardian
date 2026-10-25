# rules-builtin-tables: rules on built-in table names

Status: implemented and validated.

Product spec impact: `docs/product/spec.md` section 5 item 10 now says rules run on
API-ingested rows on any table and Guardian's own writes to its built-in tables never
run rules; section 5.1 Files item 1 no longer refuses a built-in table's name; section
8 notes that built-in writes skip ingest rules. `docs/product/overview.md`: none. The
security design (`docs/architecture/security.md`), the MCP query language reference
and `docs/changes/ingest-rules.md` say the same.

## Why

`Guardian.Rules.RuleSet` refused rule files, reads, lists, deletes and LOOKUP FROM
targets for the built-in table names (`system_stats`, `web_requests`,
`web_responses`, `query_parse_errors`, `queries`). The refusal protected nothing:
Guardian's own writers reach Storage through `Guardian.Engine.log_event/2` and
`try_log_event/2`, which call `ingest_event/2` and never run rules by construction,
and API callers could already ingest into those names. Only API ingests
(`Guardian.Engine.ingest_events/2`, from HTTP and MCP `send_events`) run rules.

## Change

1. The built-in table list and its unused `builtin_tables/0` export are removed.
   `check_table/1` checks only that the name is a valid table name, so rule file
   paths, reads, lists, deletes, misnamed-file attribution and LOOKUP FROM treat
   built-in names like any other table.
2. The LOOKUP FROM error reads "FROM must use a valid table name" (kind
   `:counter_table` unchanged).
3. Engine's split between API ingests and Guardian's own writes is unchanged.

A store holding a rule file under a built-in name (impossible to write before, but
possible by hand) now loads it instead of reporting a path error.

## Validation

Tests: rule files for every built-in name validate, a misnamed file under `queries`
is attributed to that table, LOOKUP FROM `queries` binds to a TRACK there, and with
a rule on `queries` an API ingest runs it while a `log_event` write to the same table
stores the row unchanged.
