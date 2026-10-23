# AST Subsystem

The AST parses Guardian's SQL-like query language, traverses query trees, and converts
nodes back to source.

Supported top-level statements include SELECT, SHOW TABLES, DESC, LET, and empty
statements. Rule-only UPDATE/SET/UNSET/TRACK/LOOKUP syntax, INSERT, and DELETE are
intentionally absent; API ingestion uses `/api/json/send_events` and data leaves the
store only through `Storage.SegmentExpiration`. `INSERT`, `INTO`, `VALUES`, and
`DELETE` stay reserved tokenizer keywords so table-name validation stays unchanged.

Identifiers may be dot paths (`user.name`, `users..name`) naming the stored columns of
nested fields; each run of N dots marks N - 1 list boundaries. The tokenizer
lowercases identifiers (`AST.Tokenizer.tokenize/1`), so the AST holds the lowercased
spelling; `Query.Resolver` matches it to stored names ignoring case.
There is no `table.column` qualification.

Each node is a struct whose module implements the `AST.Node` behaviour
(`use AST.Node`): `to_source/1` and `traverse/4`, and, if it can be evaluated, a
`Query.Eval` implementation in the same file or `rewrite/1`
(`lib/ast/node/CLAUDE.md`). Add parsing, unparsing, traversal, and round-trip tests
together when introducing syntax. Query functions and aggregations
are validated against their registries during parsing.

Infix and postfix operators are declared once, in `@operator_tiers` in `AST.Parser`:
node modules in precedence tiers, tightest first. Each operator's tokens come from its
node's `symbol/0`, the same spelling `to_source/1` prints, so a new operator node goes
into that table and nowhere else in the parser (`parse_operand/4` only if its operands
are not plain `left SYM right`). Compile-time checks require operators whose tokens
start another's (IS and IS NOT) to share a tier, and every symbol word to be a token
the tokenizer produces. Unary `NOT` parses its operand at `precedence(AndOperator)`,
so it covers comparisons, IS, LIKE, IN and BETWEEN but not AND or OR (`NOT a = b` is `NOT (a = b)`).
The product spec and the MCP query reference
state the precedence order; keep them in step with the tiers.

Errors that expect something throw `{:expected, what, tokens}`. The catch in
`with_source_parsed/2` formats them as "Expected X, got Y", with Y being the next
token's source text or "end of input". Other errors throw
`{:parse_error, reason, tokens}`.

Keep parser changes independent from execution changes where possible. The query engine
interprets expressions through `Query.Evaluation`.

There are no source-preserving SQL editing helpers; the AST is not edited in place.
