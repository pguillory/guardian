# AST Nodes

AST node modules define query expressions and statements. Rendering helpers such as
`Statements.RuleClauses` are not nodes. Each node does `use Guardian.AST.Node`,
which declares the `Guardian.AST.Node` behaviour (its moduledoc is the contract):

- `to_source/1` for deterministic SQL-like output
- `traverse/4` for pre/post tree walks: a node with children calls
  `traverse_fields(expr, fields, acc, pre, post)` with its child fields in a fixed
  order (a `nil` field is skipped, a list walked element by element). The order is
  load-bearing for walks that collect in visit order (the planner numbers HAVING's
  aggregate columns that way); `test/guardian/ast_test.exs` pins it and
  pre-before-children, post-after.
- optionally `rewrite/1` to an equivalent node that can be evaluated

An evaluable node implements the `Guardian.Query.Eval` protocol inside its own module,
`defimpl Guardian.Query.Eval do def eval(%@for{...}, context) ... end end`, so its evaluation
sits next to its struct. Inside the `defimpl`, `__MODULE__` is the implementation
module: write the node's struct as `%@for{}` and call its own functions (such as its
scalar `eval/2`) as `@for.eval`, since a bare `eval` is the protocol's. A rewrite-only
node needs no implementation: the protocol's `Any` fallback evaluates `rewrite/1`'s
result, and raises `Guardian.Query.Error` for a node with neither.

Two-operand infix nodes (the binary operators, and AS) do
`use Guardian.AST.Node.BinaryOperator, symbol: "..."` instead of writing their struct,
`symbol/0`, `to_source/1` and `traverse/4`; the macro does `use Guardian.AST.Node` for them.
`Guardian.AST.Parser` reads `symbol/0` from every operator node in its table (BETWEEN, ASC and
DESC define it by hand), so the parser and `to_source/1` share one spelling.

Expression nodes include identifiers, literals, function calls, aggregate calls,
aliases, parentheses, splats, cases, and operators. Statement nodes are documented in
`statements/AGENTS.md`.

Aggregate calls are planned specially by the query planner rather than evaluated as
ordinary scalar functions. Aliases are used by SELECT. TRACK and LOOKUP have rule
statement nodes, parsed only through `parse_rules/1`; `Guardian.Rules.RuleSet` validates and
resolves them for execution. Their traversal visits output fields,
counter and table names as identifiers too. Compute dependency reads from input
expressions, not from a walk over the whole statement.
