# Storage columns

This reference describes the native column API, metadata and usage patterns.
The [column editing rules](../../lib/guardian/storage/column/CLAUDE.md) are
authoritative for native safety, numerical limits, compatibility and tests;
the [parent storage rules](../../lib/guardian/storage/CLAUDE.md) govern ownership
and segment files.

`lib/guardian/storage/column/` contains support modules for Guardian's native
column format. `lib/guardian/storage/column.ex` provides the main API.

## Overview

Columns in Guardian are NIF-backed (Native Implemented Functions in C) for performance. Values are packed into efficient binary representations that support:

- Scalars: null, boolean, integer, float, string
- Lists: homogeneous lists of scalars
- Mixed types within a column (type is tracked per value)

## Files

### nif.ex

Purpose: Erlang NIF loader and stub definitions for the native column implementation.

What it does:

- Loads the compiled C NIF from `priv/column` at module initialization
- Generates a stub for each `name: arity` in its `@stubs` list; a stub exits if the NIF
  fails to load
- Acts as the bridge between Elixir and the native C code in `src/column.c`

Key functions:

- `new(capacity)`: Create mutable column reference (capacity up to 2^40)
- `append(column, value)`: Add value to mutable column
- `valid_value?(value)`: Can the value be appended to an empty column?
- `pack(column)`: Convert mutable column to packed binary
- `packed_size(column)`: Size of the column once packed, without packing it
- `allocated_size(column)`: Bytes of a mutable column's buffers (value arrays grow
  with their own counts, so a mostly nil column stays small)
- `from_list(list)`: Fast list → packed column (NIF-optimized)
- `to_list(column)`: Extract all values as Elixir list
- `count(column)`, `null_count(column)`, etc.: Get column statistics
- `metadata(column)`: Returns 8-tuple with all type counts
- Arithmetic: `add`, `subtract`, `multiply`, `divide`
- Logical: `and_oper`, `or_oper`, `not_oper`
- `filter(data_column, bool_column)`: Filter values by boolean mask
- Type conversion: `to_boolean`, `to_string`, `number_to_false`, `number_to_true`
- `min_max_number(column)`: Returns `{min, max}` tuple

Column states:

1. Mutable: Reference type, can append values, grows as needed
2. Packed: Binary type, immutable, compact storage, used in queries

Numerical limits, allocation failures, validation before mutation and nested-layer
copying requirements are in the [size and validation rules](../../lib/guardian/storage/column/CLAUDE.md#sizes-and-validation).

### metadata.ex

Purpose: Provides utilities for working with column metadata tuples without going through the NIF.

What it does:

- Defines the metadata tuple structure (8-element tuple with type counts)
- Provides arithmetic operations on metadata tuples (add, subtract)
- Used for aggregating schema information across segments

Metadata tuple structure (8 elements):

```elixir
{
  count,         # Total number of values
  null_count,    # Number of nil values
  false_count,   # Number of false values
  true_count,    # Number of true values
  int_count,     # Number of integer values
  float_count,   # Number of float values
  string_count,  # Number of string values
  list_count     # Number of list values
}
```

Key macro:

- `tuple(opts)`: Macro for pattern matching and constructing metadata tuples
  - Accepts keyword list with any subset of fields
  - Missing fields default to `_` (wildcard) in pattern matching
  - Example: `Metadata.tuple(count: c, null_count: nc)` → `{c, nc, _, _, _, _, _, _}`

Key functions:

- `add(metadata1, metadata2)`: Element-wise addition of counts
  - Works on tuples or lists of tuples (recursive)
  - Handles empty lists gracefully
- `subtract(metadata1, metadata2)`: Element-wise subtraction of counts
  - Works on tuples or lists of tuples (recursive)

Usage locations:

- `lib/guardian/storage/schema.ex`: Aggregating schema metadata across segments
- `lib/guardian/storage/segment.ex`: Constructing metadata when loading .seg files
- `lib/guardian/query/constant.ex`: Computing metadata for constant columns
- Query functions: `if`, `coalesce`, and logical operators

## Common Patterns

### Creating and populating columns

```elixir
# Fast way (NIF-optimized)
column = Column.from_list([1, 2, 3, nil, 5])

# Mutable way (less efficient)
column = Column.new(5)
Column.append(column, 1)
Column.append(column, 2)
packed = Column.pack(column)  # Convert to immutable binary
```

### Working with metadata

```elixir
# Extract metadata from column
metadata = Column.metadata(column)
# Returns: {count, null_count, false_count, true_count, int_count, float_count, string_count, list_count}

# Pattern match specific fields
require Guardian.Storage.Column.Metadata
alias Guardian.Storage.Column.Metadata

case metadata do
  Metadata.tuple(count: c, null_count: nc) when nc > 0 ->
    # Handle columns with nulls
  Metadata.tuple(int_count: ic) when ic > 0 ->
    # Handle columns with integers
  _ ->
    # Other cases
end

# Aggregate metadata from multiple segments
schema1 = %{"field" => metadata1}
schema2 = %{"field" => metadata2}
combined = Map.merge(schema1, schema2, fn _key, m1, m2 ->
  Metadata.add(m1, m2)
end)
```

### Column operations in queries

```elixir
# Arithmetic (returns new packed column)
result = Column.add(column1, column2)
result = Column.subtract(column1, column2)
result = Column.multiply(column1, column2)
result = Column.divide(column1, column2)

# Filtering
data = Column.from_list([10, 20, 30])
mask = Column.from_list([true, false, true])
filtered = Column.filter(data, mask)  # Returns [10, 30]

# Logical operations
col1 = Column.from_list([true, false, true])
col2 = Column.from_list([false, false, true])
result = Column.and_oper(col1, col2)  # Returns [false, false, true]

# Type conversions
mixed = Column.from_list([1, "hello", true, nil])
bools = Column.to_boolean(mixed)  # Keeps only booleans, rest become nil
strings = Column.to_string(mixed)  # Converts all to strings
```

## Integration with Parent Module

The parent `lib/guardian/storage/column.ex` module:

- Re-exports all NIF functions via `defdelegate`
- Adds higher-level utilities like `resize`, `duplicate`, `generate`

The [API rules](../../lib/guardian/storage/column/CLAUDE.md#api-and-native-boundary)
cover the public Column interface, direct NIF access and metadata-only operations.

## Performance Notes

### Fast operations (NIF-optimized):

- `from_list/1`: Batch conversion, much faster than repeated `append`
- All arithmetic and logical operations
- `filter/2`: Boolean masking
- Type queries: `count`, `null_count`, etc.

### Slower operations (Elixir-side):

- `resize/2`: Converts to a list to truncate, and to pad a packed column (`pad` grows only a mutable one)

### Memory characteristics:

- Mutable columns: Small overhead; value arrays and strings grow geometrically
- Packed columns: Compact binary, minimal overhead per value
- Packed format used in .seg files and query execution

## Adding operations and changing metadata

A native operation spans the C implementation, NIF stub list and parent delegation;
an Elixir operation lives in the parent module. The exact requirements are in the
[API rules](../../lib/guardian/storage/column/CLAUDE.md#api-and-native-boundary).
Metadata layout changes need a coordinated format migration; see
[metadata and compatibility](../../lib/guardian/storage/column/CLAUDE.md#metadata-and-compatibility).

### Debugging NIF issues

If NIF fails to load:

- Check that `priv/column.so` exists
- Verify C code compiles: `mix compile`
- Check for native compilation errors in build output
- Test stub error: Call any column function before NIF loads

If NIF causes crashes:

- Check Erlang crash dumps in current directory
- Enable NIF debugging in C code
- Use Valgrind or similar tools for memory issues
- Verify value types match expected format

## Gotchas

1. Mutable columns grow geometrically: They can hold about twice their packed size in memory.

2. References vs. binaries: Mutable columns are Erlang references (process-local), packed columns are binaries (can be sent across processes/nodes).

3. Type coercion is nil-happy: Most operations return nil for incompatible types rather than raising errors. This is intentional for query robustness.

4. Metadata doesn't include min/max: Use `min_max_number(column)` separately. Not stored in metadata tuple.

5. List metadata is shallow: `list_count` counts list values but doesn't recurse into list contents. Lists are opaque at metadata level.

6. The `tuple` macro is compile-time only: It generates pattern matches and can't be used for runtime tuple construction with dynamic fields.

7. Column.new() without capacity: Defaults to 0, which means you must append before using. Common pattern: `new()` then append in loop.

8. Packed columns can't be modified: Must convert to list, modify, and recreate. This is expensive - design operations to avoid it.

## Related Files

- Parent module: `lib/guardian/storage/column.ex` - Main API
- Native code: `src/column.c` - C implementation
- Tests: `test/guardian/storage/column_test.exs` - Usage examples
- Segment storage: `lib/guardian/storage/segment.ex` - Uses columns for storage
- Query evaluation: `lib/guardian/query/evaluation.ex` - Uses columns for query execution
- Schema tracking: `lib/guardian/storage/schema.ex` - Uses metadata for schema aggregation

## Possible optimizations

These are background ideas, not scheduled work; [TODO.md](../../TODO.md) tracks
planned changes and known gaps.

- Native resize could avoid list round trips for truncation and packed padding.
- Streaming large operations could reduce memory pressure.
- SIMD could accelerate arithmetic on numeric columns.

Columns hold no maps: `Guardian.Storage.Flattening` flattens nested objects into
dot-notation columns before they reach a column.
