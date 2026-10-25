# Shared timestamp reading and arithmetic

## Problem

`date_add` and `date_sub` validated and then parsed each timestamp again to get
epoch seconds, and duplicated result bounds. Timestamp extraction and formatting
also read timestamp shapes independently, with intentionally different acceptance.

## Product spec impact

None in `docs/product/overview.md` or `docs/product/spec.md`. All accepted inputs,
results, nulls and errors remain unchanged. Security architecture: none; no trust
boundary or security invariant changes.

## Ownership and compatibility

`Guardian.Timestamp.read/1` splits a raw 10-byte date and 8-byte time separated by
a space. It serves `date(ts)` and the stricter `read_fields/1` layer. It deliberately
does not validate punctuation, digits, calendar values or UTF-8.

`read_fields/1` checks the exact `YYYY-MM-DD HH:MM:SS` separator positions and
returns the six binary fields. It replaces `Guardian.Timestamp.match/0,1` and serves both
the strict calendar parser and `format_timestamp`. Calendar parsing still uses
`NaiveDateTime.from_iso8601` on the original input, preserving `from_string` and
`to_seconds` results and the latter's `ArgumentError` message on invalid values.

Formatting reads fields once, retaining its raw-byte token output, zero trimming,
token priority and named-month/hour failures. Only requested names check those
fields; an invalid day can still be formatted. The string cap still applies after
all tokens, so an invalid name after a long prefix still gives null.

`Timestamp.shift/2` owns strict single-pass parsing, epoch arithmetic and inclusive
year-0000 through year-9999 bounds. DateAdd and DateSub keep their argument guards,
and subtraction negates the delta without wrapping it. Existing arithmetic aliases
and operator argument orders remain unchanged. `ToSeconds` deliberately retains
its existing catch-all conversion to null. `from_seconds/1` is unchanged.

## Validation

Independent Claude and Codex plan reviews approved the layered raw reader and
canonical-field reader, with shared strict arithmetic. The obsolete `match/0,1` macro
was removed following plan review; all its repository callers use the field reader.

Focused timestamp utility, query, function, registry and totality coverage passed
with warnings as errors: 27 tests, zero failures. New regressions pin the three
acceptance sets, arbitrary field bytes, zero trimming, named-field failures after
the output cap, leap days, year bounds and huge deltas.

An external original-source comparison compiles renamed copies of revision
`2510159`'s Timestamp, affected function modules, FunctionCall and addition/subtraction
operators. It invokes original protocol implementations directly, preserving the
original function dispatch with renamed registry targets. Operands use unchanged
literal/identifier evaluation. Values and caught error kinds/reasons compare as
Erlang external-term bytes. Column results retain representation-kind tags, with
native resources compared by packed content rather than unique references.
All 130,495 comparisons passed against the original source. Coverage includes
malformed and boundary timestamps, invalid UTF-8 at every byte
position, nulls and wrong types, every formatter token, terminal caps, both addition
orders, all aliases, zero/one/multiple rows, constant positions, packed/mutable
columns and mixed metadata. Unexpected baseline errors fail the harness. The
harness stays outside the repository, with no dependency on Git history in tests.

Independent Claude and Codex code reviews approved after each completed all five
per-concern helper reviews of the complete diff. Nonblocking feedback clarified
current-state documentation and field naming and added direct strict-reader error,
separator and full-range shift coverage. Nonraising epoch conversion and formatter
name lookup are recorded separately as follow-ups; their current error policies
remain unchanged here.

The 16 focused utility/formatter/query tests passed after those nonblocking
adjustments. The sole full local pre-commit run passed formatting,
warnings-as-errors compilation and the default suite: 1,244 tests, zero failures,
three excluded large tests. No full run was repeated. No deployment or
production-data verification was performed.
