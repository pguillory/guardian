# in-parenthesized-list: SQL's parenthesized IN list is a parse error

## Problem

Guardian's IN takes a list in square brackets (`ip IN ['203.0.113.9']`). Written the
SQL way, `ip IN ('203.0.113.9')` parsed as IN over a grouped string. IN gives null
when its right side is not a list, so a rule such as
`SET is_blocked = true WHERE ip IN ('203.0.113.9')` was accepted and silently never
matched. With two or more elements, `ip IN ('a', 'b')` was the unhelpful parse error
"Expected punctuation: ), got ,", and `ip IN ()` "Expected expression, got )". Rule
files and queries share the parser, so both had the problem.

## Behavior after the change

1. After IN, a parenthesis holding nothing, a comma-separated sequence, or a scalar
   constant (a literal, possibly negated or in further parentheses: `('a')`, `(1)`,
   `(-1)`, `(('a'))`) is the parse error "IN takes a list in square brackets, as in
   x IN ['a', 'b']", at the parenthesis. In a rule file it is reported with the file
   and line, like any other parse error.
2. Grouping any other expression stays valid, so a list-valued operand may still be
   parenthesized: `1 IN ([1])`, `ip IN (blocked_ips)`,
   `ip IN (CASE WHEN f THEN ['a'] ELSE ['b'] END)`.
3. The parenthesized operand is parsed once (never reparsed to check it), so nested
   grouped IN operands parse in linear time.
4. An unparenthesized non-list right side (`ip IN 'a'`) and scalar expressions in
   parentheses (`ip IN ('a' || 'b')`) are unchanged: null at run time.

Upgrade effect: a table whose stored rules no longer parse rejects ingest ("rules for
<table> are invalid", spec section 5.1.3, item 6), and after a clean boot so do tables
whose rules LOOKUP from it. A stored rule using the parenthesized form, which never
matched, has that effect after the upgrade until it is fixed. Before upgrading, search
deployments' rule files case-insensitively for IN followed by optional whitespace and
`(`; that also finds the grouped forms that stay valid.

## Product spec impact

`docs/product/spec.md` section 7, item 3: `IN [list]` gains "(a parenthesized list
such as `('a', 'b')` or `('a')` is a parse error)". The "Expressions" section of
`lib/guardian/web/mcp/query_language.md` says the same and that grouping a
list-valued expression is allowed. `docs/product/overview.md`: none.

## Validation

Parser tests cover the rejected forms (empty, one and two elements, a non-literal
sequence, negated and doubly parenthesized constants, a later line) with the error
position, the accepted grouped forms, precedence after a grouped operand, and a
200-level nesting of grouped IN operands parsing in well under a second. A rule-set
test rejects the rule from the bug report with its file and line.
