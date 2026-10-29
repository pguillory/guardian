# not-in: `x NOT IN [...]`

## Problem

`ip NOT IN ['203.0.113.9']` was the parse error "Expected end of input, got NOT";
only `NOT ip IN [...]` worked, although LIKE, ILIKE and RLIKE each have an infix
`NOT` form. Rules and queries share the parser, so both lacked it.

## Behavior after the change

1. `x NOT IN list` parses to its own node, which evaluates as `NOT (x IN list)`
   (a rewrite, like NOT LIKE). With SQL's nulls: null when `x` is null or `x` is not
   found and the list holds a null, false when found, true otherwise; `x NOT IN []` is
   true even for a null `x`; a right side that is not a list gives null.
2. It shares IN's precedence tier, and unparses as `x NOT IN list`.
3. A parenthesized list is the same parse error as for IN
   ([in-parenthesized-list](in-parenthesized-list.md)).

A rule saved with NOT IN does not parse on an older build, so rolling back makes its
table's rules invalid there (spec section 5.1.3, item 6).

## Product spec impact

`docs/product/spec.md` section 7, item 3: `IN [list]` becomes `[NOT] IN [list]`, and
the precedence list's `IN` becomes `[NOT] IN`. The "Expressions" section of
`lib/guardian/web/mcp/query_language.md` adds `x NOT IN [a, b, c]` with its null
behavior and the same precedence change. `docs/product/overview.md`: none.

## Validation

Parser tests cover parsing into the node and unparsing, precedence against NOT, AND
and `=`, the incomplete `a NOT IN`, the rewrite round trip, the parenthesized-list
error, and alternating nested IN/NOT IN groups. Operator tests cover the null matrix,
empty lists, non-list right sides, and segment-wide against row-by-row results. The
totality test includes `a NOT IN b`, and an ingest test runs a rule with NOT IN in
its WHERE, including an event without the field.
