# Operator Nodes

Operator modules represent arithmetic, comparison, boolean, string, list, and regex
expressions. Each node owns its scalar evaluation behavior and AST traversal/source
formatting. `Query.Evaluation` applies that behavior to constants or whole columns.

A two-operand infix node (`left SYM right`) does
`use AST.Node.BinaryOperator, symbol: "SYM"`, which generates its struct, `symbol/0`,
`to_source/1` and `traverse/4`, so the module holds only its `Query.Eval`
implementation, its scalar `eval/2`, or `rewrite/1`. Nodes of any other shape (NOT,
negation, BETWEEN, list literals) write their struct, `to_source/1` and `traverse/4`
themselves; BETWEEN also defines `symbol/0`. A new infix or postfix operator goes into
`@operator_tiers` in `AST.Parser` (`lib/ast/CLAUDE.md`).

`comparison.ex` is not a node: `AST.Node.Operators.Comparison` holds the evaluation
`<` and `<=` share, including the segment-wide fast path against a number literal.
`>`, `>=` and BETWEEN rewrite to them. A fast-path change must keep segment results
equal to row-by-row ones (the comparison tests check this with
`Query.EvaluationTestCase.eval_segment_and_rows/2`).

Preserve SQL null semantics and type handling when changing an operator. Regex patterns
are validated and executed with Hyperscan. Add scalar, columnar, null, and mixed-type
tests for behavior changes.
