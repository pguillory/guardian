# Statement Nodes

Guardian supports these statement families:

- SELECT for reading, filtering, grouping, sorting, and limiting
- SHOW TABLES and DESC for storage-backed introspection
- LET for query substitutions
- NullStatement for empty semicolon-delimited statements
- SetStatement and UnsetStatement, the rule statements, parsed only from rule files
  by `AST.Parser.parse_rules/1` (`lib/rules/CLAUDE.md`)
- TrackStatement and LookupStatement, parsed counter rule syntax with canonical
  source and traversal; `Rules.RuleSet` validates and resolves them for execution

There is no UPDATE transformation syntax, INSERT, or DELETE statement. API ingestion
uses `/api/json/send_events`.

Statement modules implement `to_source/1` and `traverse/4`. Parser tests must cover
construction and round trips; execution behavior belongs in query tests.

Counter clauses follow source order in traversal. TRACK holds `field`,
`aggregate_expr`, `by_exprs`, `where_expr`, `last_expr` (a string literal);
LOOKUP holds `field`, `counter`, `from_table`, `by_exprs`, `where_expr`.
Omitted BY is an empty list; omitted FROM/WHERE is nil. The parser reuses the query
aggregate registry and arity checks (including count(*) becoming count()), but
counter aggregate restrictions, scalar inputs, LAST bounds and FROM table validity
belong to Rules.Validation and whole-set Rules.RuleSet preparation.
