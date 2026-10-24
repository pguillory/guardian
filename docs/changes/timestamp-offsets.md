# timestamp-offsets: time arithmetic applies ISO 8601 UTC offsets

## Problem

`Timestamp.from_string/1` and `Timestamp.to_seconds/1` read timestamps with
`NaiveDateTime.from_iso8601/1`, which accepts a UTC offset and throws it away. So
`date_add('2020-01-01T19:35:00+02:00', 0)` gave `2020-01-01 19:35:00` instead of
`17:35:00`, and `to_seconds` was off by the offset. `Z` worked only because it is a
zero offset.

## Behavior after the change

1. Time arithmetic (`date_add`, `adddate`, `date_sub`, `subdate`, a timestamp string
   `+` or `-` an integer, `to_seconds` and `unix_timestamp`) reads an ISO 8601 date
   and time in the extended form `YYYY-MM-DDTHH:MM:SS`, with `T` or a space between
   them, optional fractional seconds (dropped), and an optional offset: `Z`,
   `+HH:MM`, `+HHMM` or `+HH` (or `-`). The offset is applied, so
   `2020-01-01T19:35:00+02:00` is `2020-01-01 17:35:00`. Other ISO 8601 forms (a date
   alone, the basic form, week or ordinal dates) give null, as before.
2. A time without an offset is taken as UTC, as before.
3. Timestamp results stay UTC `YYYY-MM-DD HH:MM:SS`, and `to_seconds` gives seconds
   since 1970 UTC. Null, as before, for input that can't be read; also null now for
   an offset Elixir can't read (`+24:00`, `+2`), which used to be ignored, and for a
   time whose UTC form falls outside years 0000 to 9999
   (`0000-01-01T00:30:00+01:00`), including a negative year such as
   `-0001-01-01T00:00:00`, which `to_seconds` used to answer.
4. Unchanged: Guardian parses no time on ingest; comparison and sorting are string
   operations and apply no offset; `format_timestamp` and `date(ts)` read only
   `YYYY-MM-DD HH:MM:SS`.

## Product spec impact

`docs/product/spec.md` section 6.4 now states the formats time arithmetic reads and
that offsets are applied; the "Timestamps" section of `lib/web/mcp/query_language.md`
says the same. `docs/product/overview.md`: none.

## Validation

`test/utils/timestamp_test.exs`: each offset form, `Z`, fractional seconds and no
offset give the same UTC time from `from_string/1` and `to_seconds/1`; an offset that
crosses a year; unreadable offsets and UTC times just outside the year range are
errors, and the range's ends are accepted. `test/query/function/date_add_test.exs`:
`date_add`, `date_sub`, `+`, `-` and `to_seconds` of offset timestamps (one with
fractional seconds) in a query. `test/query/totality_test.exs` gains an in-range
offset timestamp (`2026-01-01T00:00:00+02:00`) beside the out-of-range one, and still
finds every function and operator total and in agreement over them.
