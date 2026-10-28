# Implementing query functions

This contributor guide explains function dispatch and implementation patterns.
The [query function editing rules](../../lib/guardian/query/function/AGENTS.md)
are authoritative for registration, evaluation contracts, totality, native dispatch,
regex safety and tests. Read the applicable ancestor instructions before editing.

## Purpose

Guardian's query language supports SQL-like functions (e.g., `abs()`, `concat()`,
`email_domain()`). Each function is implemented as a separate module under
`lib/guardian/query/function/`. A module provides scalar evaluation (`eval/N`, one
value per argument), and optionally its own columnar evaluation (`eval2/2`, whole
columns at once).

## Architecture

### Function registration

The registry in `lib/guardian/query/function.ex` maps names and arities to modules:

```elixir
@names_and_mods [
  {"abs", 1, Guardian.Query.Function.Abs},
  {"email_domain", 1, Guardian.Query.Function.EmailDomain},
]
```

### Function Dispatch

When a query is evaluated:

1. Parser creates `%Guardian.AST.Node.FunctionCall{name: "abs", args: [expr]}`
2. The `Guardian.Query.Eval` protocol dispatches to `Guardian.AST.Node.FunctionCall`'s implementation
3. That looks the module up by name and arity with
   `Guardian.Query.Function.name_and_arity_to_mod/2`; an unregistered name and arity evaluates
   to nulls
4. If the module defines `eval2/2`, that evaluates the call. Otherwise the default
   applies: each argument is evaluated in order and `eval/N` is mapped over the
   columns with `ColumnOrConstant.map` (arity 1 to 4), or, for a zero-argument call,
   called once per row with `ColumnOrConstant.generate`

## Function Patterns

### Pattern 1: Simple Function (the default)

Most functions are only their `eval/N`; the default evaluation maps it over the
argument columns:

```elixir
defmodule Guardian.Query.Function.Abs do
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
defmodule Guardian.Query.Function.Substr do
  def eval(value, start) when is_binary(value) and is_integer(start) and start >= 1 do
    String.slice(value, start - 1, byte_size(value))
  end

  def eval(_, _) do
    nil
  end

  def eval(value, start, count) when ... do
    String.slice(value, start - 1, count)
  end

  def eval(_, _, _) do
    nil
  end
end
```

### Pattern 3: Constant Function (No Arguments)

A zero-argument function without `eval2/2` calls `eval/0` once per row (Pattern 4).
A deterministic one should define `eval2/2` and return one `Constant` instead:

```elixir
defmodule Guardian.Query.Function.Pi do
  alias Guardian.Query.Constant
  alias Guardian.Query.Evaluation

  def eval2(context, %Guardian.AST.Node.FunctionCall{args: []}) do
    Constant.duplicate(__MODULE__.eval(), Evaluation.context_count(context))
  end

  def eval do
    :math.pi()
  end
end
```

### Pattern 4: Non-Deterministic Function

For functions that need a different value per row (random, UUIDs), the default
evaluation calls `eval/0` once per row, so `eval/0` is all they need. The [registration rules](../../lib/guardian/query/function/AGENTS.md#registration-and-evaluation)
cover the non-deterministic function list:

```elixir
defmodule Guardian.Query.Function.GenerateUUID do
  def eval do
    UUID.uuid4()
  end
end
```

### Pattern 5: Variable Arity (One Call Over Every Argument)

For functions that accept many arities, evaluate every argument and combine each row's
values in one call with `ColumnOrConstant.map_n/2`. The [whole-join rule](../../lib/guardian/query/function/AGENTS.md#registration-and-evaluation)
keeps a capped string's result a prefix of the whole join.

```elixir
defmodule Guardian.Query.Function.Concat do
  def eval2(context, %Guardian.AST.Node.FunctionCall{args: exprs}) do
    exprs
    |> Enum.map(&Guardian.Query.Eval.eval(&1, context))
    |> ColumnOrConstant.map_n(&join/1)
  end
end
```

### Pattern 6: Short-Circuit Optimization

For conditional functions, check column metadata to avoid unnecessary evaluation:

```elixir
defmodule Guardian.Query.Function.If do
  alias Guardian.Query.ColumnOrConstant
  alias Guardian.Storage.Column.Metadata
  require Metadata

  def eval2(context, %Guardian.AST.Node.FunctionCall{args: [expr1, expr2, expr3]}) do
    column1 = Guardian.Query.Eval.eval(expr1, context)

    case ColumnOrConstant.metadata(column1) do
      # All true - only evaluate then branch
      [Metadata.tuple(true_count: count, count: count) | _] ->
        Guardian.Query.Eval.eval(expr2, context)

      # All false - only evaluate else branch
      [Metadata.tuple(false_count: count, count: count) | _] ->
        Guardian.Query.Eval.eval(expr3, context)

      # Mixed - evaluate both and select
      [Metadata.tuple() | _] ->
        column2 = Guardian.Query.Eval.eval(expr2, context)
        column3 = Guardian.Query.Eval.eval(expr3, context)
        ColumnOrConstant.map(column1, column2, column3, &__MODULE__.eval/3)
    end
  end
end
```

### Pattern 7: Compile-Time Optimization

For functions that can optimize when arguments are literals:

```elixir
defmodule Guardian.Query.Function.Replace do
  # If pattern is a literal string, compile regex once
  def eval2(context, %Guardian.AST.Node.FunctionCall{args: [expr1, expr2, expr3]}) do
    with %Guardian.AST.Node.Literal{value: pattern} when is_binary(pattern) <- expr2,
         {:ok, regex} <- Guardian.Query.Regex.compile(pattern) do
      # Use compiled pattern for all rows
      column1 = Guardian.Query.Eval.eval(expr1, context)
      column3 = Guardian.Query.Eval.eval(expr3, context)
      ColumnOrConstant.map(column1, column3, fn
        string, replacement when is_binary(string) and is_binary(replacement) ->
          Guardian.Query.Regex.replace(regex, string, replacement)

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

## Common Utilities

### Guardian.Query.ColumnOrConstant

Handles dual representation of columnar data:

- `map(column, fun)` - Map unary function over column
- `map(col1, col2, fun)` - Map binary function over two columns
- `map(col1, col2, col3, fun)` - Map ternary function
- `map(col1, col2, col3, col4, fun)` - Map 4-ary function
- `generate(fun, count)` - Generate `count` values by calling `fun` repeatedly
- `metadata(column)` - Get column metadata for optimizations

### Guardian.Query.NativeDispatch

- `evaluate(operation, col, fun)` / `evaluate(operation, col1, col2, fun)` - Shared
  scalar/native selection for supported native-backed operations; see the
  [dispatch rules](../../lib/guardian/query/function/AGENTS.md#registration-and-evaluation).

### Guardian.Query.Eval and Guardian.Query.Evaluation

- `Guardian.Query.Eval.eval(expr, context)` - Evaluate an AST expression (argument)
- `Guardian.Query.Evaluation.context_count(context)` - Get number of rows in context

### Guardian.Query.Constant

- `duplicate(value, count)` - Create constant repeated `count` times

## Adding a New Function

1. Create new file `lib/guardian/query/function/my_function.ex`
2. Implement the module following one of the patterns above
3. Register in `lib/guardian/query/function.ex`
4. Create test file `test/guardian/query/function/my_function_test.exs`
5. Run `mix test` to verify

Example for adding `trim_start(string)`:

```elixir
# lib/guardian/query/function/trim_start.ex
defmodule Guardian.Query.Function.TrimStart do
  def eval(value) when is_binary(value) do
    String.trim_leading(value)
  end

  def eval(_) do
    nil
  end
end
```

Then register in `lib/guardian/query/function.ex`:

```elixir
@names_and_mods [
  # ... existing functions ...
  {"trim_start", 1, Guardian.Query.Function.TrimStart},
]
```

## Type handling and totality

The [Totality rules](../../lib/guardian/query/function/AGENTS.md#totality)
cover numeric bounds, null fallbacks, string cuts and URL/regex safety. The Abs
example above illustrates guarded types and a nil fallback. The registered functions
are also exercised across rows, constants and columns by the totality grid.

## Function Categories

### Math Functions

`abs`, `ceil`, `floor`, `round`, `sqrt`, `power`, `exp`, `log`, `log2`, `log10`, `factorial`, `mod`, `div`, `pi`

### String Functions

`concat`, `length`, `lower`, `upper`, `trim`, `ltrim`, `rtrim`, `lpad`, `rpad`, `substr`, `reverse`, `replace`, `normalize`, `to_string`

### Email Functions

`email_domain`, `email_username`

### URL Functions

`url_scheme`, `url_host`, `url_port`, `url_path`, `url_fragment`, all through
`Guardian.Query.URL.parse/1`

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

## Specialized evaluation

`replace` compiles literal patterns once through `Guardian.Query.Regex`; its bounded
execution policy is in the [editing rules](../../lib/guardian/query/function/AGENTS.md#totality).
There is no `jq()`; the parser rejects it with a message.
`cosine_similarity` computes similarity between two list vectors.

## Testing

Each function should have a test file in `test/guardian/query/function/`:

```elixir
defmodule Guardian.Query.Function.EmailDomainTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "email_domain function" do
    assert eval("email_domain('user@domain.com')") === "domain.com"
    assert eval("email_domain('invalid')") === nil
    assert eval("email_domain(123)") === nil
  end
end
```

The `Guardian.Query.EvaluationTestCase` provides the `eval/2` helper for easy testing.

## Related Files

- `lib/guardian/query/function.ex` - Function registry
- `lib/guardian/query/evaluation.ex` - Evaluation engine that calls functions
- `lib/guardian/query/column_or_constant.ex` - Columnar data utilities
- `lib/guardian/query/native_dispatch.ex` - Scalar/native selection for native-backed operations
- `lib/guardian/ast.ex` - AST node definitions
- `test/guardian/query/function/` - Function tests
