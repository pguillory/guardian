# timestamp-offsets: one UTC timestamp format

## Problem

Guardian timestamps are UTC strings in one format, `YYYY-MM-DD HH:MM:SS`.
Originally time arithmetic silently discarded numeric offsets; commit `b7e99ab`
then applied them. That added time-zone conversion where Guardian needs only UTC.
This change replaces conversion with strict format validation.

## Behavior after the change

1. Time arithmetic (`date_add`, `adddate`, `date_sub`, `subdate`, a timestamp string
   `+` or `-` an integer, `to_seconds` and `unix_timestamp`) accepts only UTC
   `YYYY-MM-DD HH:MM:SS`: exactly 19 bytes with a space, valid calendar fields, and
   years 0000 to 9999. Invalid input returns null through the query functions.
2. Every numeric offset is rejected, including `+HH:MM`, `+HHMM`, `+HH`, their
   negative forms, and numeric zero offsets. Nothing is converted or silently
   discarded: `date_add('2020-01-01 19:35:00+02:00', 0)` returns null.
3. A `T` separator, trailing `Z`, fractional seconds, surrounding whitespace and
   other date/time formats also return null. Timestamp results keep the canonical
   UTC format; `to_seconds` returns seconds since 1970 UTC. Arithmetic outside the
   supported year range returns null.
4. Guardian still stores ordinary strings without parsing timestamps on ingest.
   Comparison and sorting operate on raw strings. `date(ts)` and
   `format_timestamp` already require the space-separated format without a suffix;
   their existing field extraction and formatting behavior is unchanged.

## Compatibility decision

Keep the accepted set to the single canonical format, rejecting `T`, `Z` and
fractions even though the old parser accepted them before the offset fix. All
timestamp producers in this repository use `Guardian.Timestamp.now/0` or
`Guardian.Timestamp.from_seconds/1`: built-in event tables, `now()`/`current_timestamp`, build
stamps and segment timestamps. Both helpers produce `YYYY-MM-DD HH:MM:SS`. The only
other timestamp-string parser callers are time arithmetic and epoch conversion;
ISO variants appeared in utility tests, not in repository producers. No timestamp
rewrite or data migration is part of this change.

## Product spec impact

`docs/product/spec.md` section 6.4 now specifies the exact UTC format and null for
numeric offsets and all alternate formats. The MCP query description and
`lib/web/mcp/query_language.md` state that contract, and README timestamp guidance
names it. `docs/product/overview.md`: none. Security architecture: none; no trust
boundary or security invariant changes.

## Validation

Focused coverage in `test/utils/timestamp_test.exs` checks canonical round trips,
epoch, leap day and year boundaries, and rejection of offset forms of both signs
(including zero) with either separator, alternate formats, invalid calendar fields,
invalid UTF-8 and nonstrings. `test/query/timestamp_test.exs` checks exact results
and nulls for every time-arithmetic alias, both addition orders, subtraction,
`date(ts)` and `format_timestamp`, over literals, event maps and mixed segment
columns, including mixed strings, integers and nulls. Totality inputs retain
numeric-offset timestamps as invalid values and include the year-0000 lower bound.

On Elixir 1.19.3 / OTP 28.5.0.8, formatting and warnings-as-errors compilation
pass. The focused suite passes (34 tests, zero failures), and the full default
suite passes with zero failures (three `:large` tests excluded). No deployment
or production-data verification is part of this change.
