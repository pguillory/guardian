# Query Functions Directory

This directory contains individual function implementations for Guardian's SQL-like query language. Each file implements one function (or a related set of arities for one function).

## Purpose

Guardian's query language supports SQL-like functions (e.g., `abs()`, `concat()`, `email_domain()`). Each function is implemented as a separate module in this directory. A module provides scalar evaluation (`eval/N`, one value per argument), and optionally its own columnar evaluation (`eval2/2`, whole columns at once).

## Architecture

### Function Registration

Functions are NOT auto-discovered. Each function must be manually registered in the parent file `lib/query/function.ex`:

```elixir
@names_and_mods [
  {"abs", 1, Query.Function.Abs},
  {"email_domain", 1, Query.Function.EmailDomain},
  # ... etc
]
```

The registration tuple is: `{function_name, arity, module}`

When several names share a module (aliases such as `curdate` for `Date`), a module's
own `eval2/2` must match on arguments only, never on `name:`, or the alias raises
`FunctionClauseError`. Modules without their own `eval2/2` cannot hit this. `Query.FunctionRegistryTest` evaluates every registered name.

### Function Dispatch

When a query is evaluated:

1. Parser creates `%AST.Node.FunctionCall{name: "abs", args: [expr]}`
2. The `Query.Eval` protocol dispatches to `AST.Node.FunctionCall`'s implementation
3. That looks the module up by name and arity with
   `Query.Function.name_and_arity_to_mod/2`; an unregistered name and arity evaluates
   to nulls
4. If the module defines `eval2/2`, that evaluates the call. Otherwise the default
   applies: each argument is evaluated in order and `eval/N` is mapped over the
   columns with `ColumnOrConstant.map` (arity 1 to 4), or, for a zero-argument call,
   called once per row with `ColumnOrConstant.generate`

### What a Module Defines

1. `eval(value)` or `eval(value1, value2)` etc - Scalar evaluation
   - Takes: individual scalar values (one per argument)
   - Returns: result value or `nil` on error/invalid input
   - Pure function that performs the actual operation
   - Should handle type errors gracefully (return `nil`)
   - A module without its own `eval2/2` needs one `eval/N` per registered arity

2. `eval2(context, %AST.Node.FunctionCall{})` - Columnar evaluation (optional)
   - Define it only when the default per-row evaluation is not enough: short
     circuits (`if`, `coalesce`), compiling a literal argument once (`replace`), a
     NIF fast path (`to_boolean`, `to_string` with `ColumnOrConstant.map_or_nif`),
     rewrites (`concat`), or a constant (`pi`)
   - Takes: evaluation context (SegmentSnapshot or event map) and function call AST
   - Returns: `%Column{}` or `%Constant{}` (from `Query.ColumnOrConstant`)
   - Evaluates arguments using `Query.Eval.eval/2`
   - When defined, it handles every arity the module is registered for

## Function Patterns

### Pattern 1: Simple Function (the default)

Most functions are only their `eval/N`; the default evaluation maps it over the
argument columns:

```elixir
defmodule Query.Function.Abs do
  def eval(value) when is_number(value) do
    abs(value)
  end

  def eval(_) do
    nil
  end
end
```

### Pattern 2: Several Arities

Define one `eval/N` per registered arity:

```elixir
defmodule Query.Function.Substr do
  def eval(value, start) when is_binary(value) and is_integer(start) and start >= 1 do
    String.slice(value, start - 1, byte_size(value))
  end

  def eval(_, _), do: nil

  def eval(value, start, count) when ... do
    String.slice(value, start - 1, count)
  end

  def eval(_, _, _), do: nil
end
```

### Pattern 3: Constant Function (No Arguments)

A zero-argument function without `eval2/2` calls `eval/0` once per row (Pattern 4).
A deterministic one should define `eval2/2` and return one `Constant` instead:

```elixir
defmodule Query.Function.Pi do
  alias Query.Constant
  alias Query.Evaluation

  def eval2(context, %AST.Node.FunctionCall{args: []}) do
    Constant.duplicate(__MODULE__.eval(), Evaluation.context_count(context))
  end

  def eval do
    :math.pi()
  end
end
```

### Pattern 4: Non-Deterministic Function

For functions that need a different value per row (random, UUIDs), the default
evaluation calls `eval/0` once per row, so `eval/0` is all they need. Also add them to
`Query.Evaluation.@non_deterministic_functions` (see Performance Considerations):

```elixir
defmodule Query.Function.GenerateUUID do
  def eval do
    UUID.uuid4()
  end
end
```

### Pattern 5: Variable Arity (Recursive Rewrite)

For functions that accept multiple arities, rewrite to binary operations:

```elixir
defmodule Query.Function.Concat do
  # concat/2
  def eval2(context, %AST.Node.FunctionCall{args: [expr1, expr2]}) do
    # ... base case
  end

  # concat/3+ - rewrite concat(a,b,c) as concat(concat(a,b), c)
  def eval2(context, %AST.Node.FunctionCall{args: [expr1, expr2, expr3 | exprs]}) do
    expr_1_expr_2 = %AST.Node.FunctionCall{name: "concat", args: [expr1, expr2]}
    Query.Eval.eval(
      %AST.Node.FunctionCall{name: "concat", args: [expr_1_expr_2, expr3 | exprs]},
      context
    )
  end
end
```

### Pattern 6: Short-Circuit Optimization

For conditional functions, check column metadata to avoid unnecessary evaluation:

```elixir
defmodule Query.Function.If do
  alias Query.ColumnOrConstant
  alias Storage.Column.Metadata
  require Metadata

  def eval2(context, %AST.Node.FunctionCall{args: [expr1, expr2, expr3]}) do
    column1 = Query.Eval.eval(expr1, context)

    case ColumnOrConstant.metadata(column1) do
      # All true - only evaluate then branch
      [Metadata.tuple(true_count: count, count: count) | _] ->
        Query.Eval.eval(expr2, context)

      # All false - only evaluate else branch
      [Metadata.tuple(false_count: count, count: count) | _] ->
        Query.Eval.eval(expr3, context)

      # Mixed - evaluate both and select
      [Metadata.tuple() | _] ->
        column2 = Query.Eval.eval(expr2, context)
        column3 = Query.Eval.eval(expr3, context)
        ColumnOrConstant.map(column1, column2, column3, &__MODULE__.eval/3)
    end
  end
end
```

### Pattern 7: Compile-Time Optimization

For functions that can optimize when arguments are literals:

```elixir
defmodule Query.Function.Replace do
  # If pattern is a literal string, compile regex once
  def eval2(context, %AST.Node.FunctionCall{args: [expr1, expr2, expr3]}) do
    with %AST.Node.Literal{value: pattern} when is_binary(pattern) <- expr2,
         {:ok, regex} <- Query.Regex.compile(pattern) do
      # Use compiled pattern for all rows
      column1 = Query.Eval.eval(expr1, context)
      column3 = Query.Eval.eval(expr3, context)
      ColumnOrConstant.map(column1, column3, fn
        string, replacement when is_binary(string) and is_binary(replacement) ->
          Query.Regex.replace(regex, string, replacement)

        _, _ ->
          nil
      end)
    else
      _ ->
        # Pattern not constant, return nil for all rows
        Constant.duplicate(nil, Evaluation.context_count(context))
    end
  end
end
```

## File Organization

Each function gets its own file named in snake_case after the function:

- `abs.ex` - `abs()` function
- `email_domain.ex` - `email_domain()` function
- `url_host.ex` - `url_host()` function
- etc.

Module names use PascalCase: `Query.Function.EmailDomain`

## Common Utilities

### Query.ColumnOrConstant

Handles dual representation of columnar data:

- `map(column, fun)` - Map unary function over column
- `map(col1, col2, fun)` - Map binary function over two columns
- `map(col1, col2, col3, fun)` - Map ternary function
- `map(col1, col2, col3, col4, fun)` - Map 4-ary function
- `generate(fun, count)` - Generate `count` values by calling `fun` repeatedly
- `metadata(column)` - Get column metadata for optimizations

### Query.Eval and Query.Evaluation

- `Query.Eval.eval(expr, context)` - Evaluate an AST expression (argument)
- `Query.Evaluation.context_count(context)` - Get number of rows in context

### Query.Constant

- `duplicate(value, count)` - Create constant repeated `count` times

## Adding a New Function

1. Create new file `lib/query/function/my_function.ex`
2. Implement the module following one of the patterns above
3. Register in `lib/query/function.ex`
4. Create test file `test/query/function/my_function_test.exs`
5. Run `mix test` to verify

Example for adding `trim_start(string)`:

```elixir
# lib/query/function/trim_start.ex
defmodule Query.Function.TrimStart do
  def eval(value) when is_binary(value) do
    String.trim_leading(value)
  end

  def eval(_) do
    nil
  end
end
```

Then register in `lib/query/function.ex`:

```elixir
@names_and_mods [
  # ... existing functions ...
  {"trim_start", 1, Query.Function.TrimStart},
]
```

## Totality

Every function and operator is total: on any input it returns a value storage can
hold, or `nil`. It never raises, and never returns a bignum, a non-finite float, or a
list nested deeper than a list of lists. `Query.Numeric` states the rules:

- An integer result wraps to int64 with `Query.Numeric.wrap/1`, matching the column
  NIF's wrapping `+ - *` (`src/column.c`), so both evaluation paths agree.
- Float arithmetic that overflows raises `ArithmeticError` in Erlang: catch
  `:error, :badarith` and return `nil`.
- A result with no good value (division by zero, a domain error, a rounded float
  outside int64, `Query.Numeric.int64_or_nil/1`) is `nil`.
- `Query.ColumnOrConstant.list_or_constant_to_column_or_constant/1` turns any
  remaining unstorable value into `nil` as the result is built, a backstop rather
  than a substitute for the rules above.

`test/query/totality_test.exs` runs every registered function and operator over a grid
of edge values per event, against constants and over columns, and checks that the
three agree. A new function is covered automatically; add an edge value there when a
new kind of input matters.

## Type Handling

Functions should handle type mismatches gracefully:

- Return `nil` for unexpected types (don't raise errors)
- Use guard clauses to check types: `when is_binary(value)`
- Provide fallback clause: `def eval(_), do: nil`

Examples:
```elixir
# Good - graceful handling
def eval(value) when is_number(value), do: abs(value)
def eval(_), do: nil

# Bad - will crash on wrong type
def eval(value), do: abs(value)
```

## Performance Considerations

1. Columnar operations are HOT PATH
   - These run on potentially billions of events
   - Keep `eval/N` functions simple and fast
   - Avoid allocations in tight loops
   - Consider NIFs for computationally intensive operations

2. No compile-time constant folding
   - Queries evaluate constant expressions per segment, as written
   - `Query.Evaluation.pre_eval/1` folds constants but only tests use it; it skips
     the functions in `Query.Evaluation.@non_deterministic_functions` (random, now,
     generate_uuid, ...). Add a new non-deterministic function to that list

3. Short-circuit when possible
   - Check column metadata for all-true/all-false conditions
   - Avoid evaluating branches that won't be used (see `if` and `coalesce`)

## Function Categories

### Math Functions
`abs`, `ceil`, `floor`, `round`, `sqrt`, `power`, `exp`, `log`, `log2`, `log10`, `factorial`, `mod`, `div`, `pi`

### String Functions
`concat`, `length`, `lower`, `upper`, `trim`, `ltrim`, `rtrim`, `lpad`, `rpad`, `substr`, `reverse`, `replace`, `normalize`, `to_string`

### Email Functions
`email_domain`, `email_username`

### URL Functions
`url_scheme`, `url_host`, `url_port`, `url_path`, `url_fragment`

### Hash Functions
`md5`, `sha1`, `sha256`, `sha512`

### Date/Time Functions
`date`, `now`, `date_add`, `date_sub`, `to_seconds`, `format_timestamp`, `interval`

### Type Functions
`type`, `to_boolean`, `to_string`

### Conditional Functions
`if`, `coalesce`

### Utility Functions
`random`, `generate_uuid`, `ip_to_integer`, `cosine_similarity`

## Special Functions

### replace - Regular expression replacement

Runs through `Query.Regex`, the only place patterns are compiled and run (`:re` with
mandatory `match_limit` and `match_limit_recursion`). Never call `:re` directly from a
function, and never reintroduce a regex NIF: the Hyperscan NIF this replaced aborted
the VM on growing or overlapping matches. There is no `jq()`; the parser rejects it with a
message.

### cosine_similarity - Vector similarity

Operates on lists, computes cosine similarity between two vectors.

## Testing

Each function should have a test file in `test/query/function/`:

```elixir
defmodule Query.Function.EmailDomainTest do
  use Query.EvaluationTestCase, async: true

  test "email_domain function" do
    assert eval("email_domain('user@domain.com')") === "domain.com"
    assert eval("email_domain('invalid')") === nil
    assert eval("email_domain(123)") === nil
  end
end
```

The `Query.EvaluationTestCase` provides the `eval/2` helper for easy testing.

## Gotchas

1. Always register new functions in `lib/query/function.ex` - they won't work otherwise
2. Module name must match the pattern `Query.Function.FunctionName`
3. Return `nil` for type errors and for results with no good value; never raise
   (see "Totality")
4. For multi-arity functions, register EACH arity separately in the parent module
5. Use `ColumnOrConstant.map` not regular `Enum.map` - different representation
6. A module without `eval2/2` needs `eval/N` for each registered arity; `eval2/2` is
   optional and, when defined, replaces the default for all of the module's arities
7. Zero-argument functions without `eval2/2` call `eval/0` once per row; a
   deterministic constant should define `eval2/2` with `Constant.duplicate`
8. SQL function names are case-insensitive in queries but lowercase in registration
9. Function aliases (like `unix_timestamp` → `to_seconds`) just register the same module under multiple names

## Related Files

- `lib/query/function.ex` - Function registry
- `lib/query/evaluation.ex` - Evaluation engine that calls functions
- `lib/query/column_or_constant.ex` - Columnar data utilities
- `lib/ast.ex` - AST node definitions
- `test/query/function/` - Function tests
