# integer-literal-range: integer literals outside int64 are parse errors

## Problem

The tokenizer turned an integer literal into an Erlang integer with no range check, so
`SELECT 99999999999999999999` parsed and then failed evaluation with a `MatchError`
when the bignum became a column or constant, which storage refuses.
`-9223372036854775808` failed the same way, since it is unary minus applied to 2^63.
A float literal too large to represent (`1e400`) was already the parse error
"Number out of range" at the number.

## Behavior after the change

1. An integer literal outside int64 is the parse error "Number out of range" at the
   start of the number, exactly like an oversized float. The tokenizer skips leading
   zeros and counts the significant digits before converting: more than 19 is out of
   range without converting, so a huge literal builds no bignum; 19 digits are
   converted and compared with the maximum.
2. Literals are unsigned (minus is an operator), so they run from 0 to
   9223372036854775807. 9223372036854775808 is out of range, and the smallest int64
   is written `-9223372036854775807 - 1`.
3. Everything that reads an integer token gets the same rule: expressions, `LIMIT`,
   and `INTERVAL n UNIT` (an oversized `INTERVAL` number is now a parse error). The
   query is rejected before it runs.
4. Scanner errors still win over evaluation errors: in `SELECT 99999999999999999999 #`
   the unexpected character is reported.

## Product spec impact

`docs/product/spec.md` section 7, item 3, and the "Expressions" section of
`lib/guardian/web/mcp/query_language.md` now state the range of integer literals (0 to
9223372036854775807), the parse error, and how to write the smallest int64.
`docs/product/overview.md`: none.

## Validation

Tokenizer tests cover 2^63, 19-, 20- and 25-digit literals, the maximum accepted
with and without leading zeros, max + 1 with leading zeros rejected, a 19-digit value
below the maximum, `000` and a long all-zero literal, error positions on later lines
and after multi-byte characters, scanner-error precedence, and a 1 MB digit run
rejected quickly. Parser tests cover `LIMIT`, `INTERVAL` and `-9223372036854775808`
(reported at the magnitude); a query test evaluates `-9223372036854775807 - 1`.

The plan's rule-validation test is not here: there is no rule engine on main.

Found while building, not changed here: an in-range `INTERVAL n WEEK` whose seconds
overflow int64 (`INTERVAL 15250284452472 WEEK`), like constant arithmetic that
overflows (`15250284452472 * 604800`), fails the query with "argument error" rather
than giving null.
