# Statement Nodes

Guardian supports these statement families:

- SELECT for reading, filtering, grouping, sorting, and limiting
- SHOW TABLES and DESC for storage-backed introspection
- LET for query substitutions
- NullStatement for empty semicolon-delimited statements
- SetStatement and UnsetStatement, the rule statements, parsed only from rule files
  by `AST.Parser.parse_rules/1` (`lib/rules/CLAUDE.md`)

There is no UPDATE transformation syntax, INSERT, or DELETE statement. API ingestion
uses `/api/json/send_events`.

Statement modules implement `to_source/1` and `traverse/4`. Parser tests must cover
construction and round trips; execution behavior belongs in query tests.
