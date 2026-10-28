# Storage Columns

For API descriptions, metadata layout, examples, performance and debugging, see
the [column reference](../../../../docs/architecture/storage-columns.md).
This file holds the editing rules; the [parent storage rules](../AGENTS.md) also apply.

## API and native boundary

- Use `Guardian.Storage.Column` for normal operations; call
  `Guardian.Storage.Column.NIF` directly only to bypass parent logic.
  Elixir-side operations belong in `lib/guardian/storage/column.ex`.
  Use `Guardian.Storage.Column.Metadata` for metadata-only aggregation.
- Keep `nif.ex`'s `@stubs` in `src/column.c`'s `nif_funcs[]` order and match
  every name and arity. A new C operation needs both entries and a parent
  `defdelegate`. `test/guardian/storage/column/nif_test.exs` checks parity.
- Mutable columns are process-local references; they never leave their owning
  Segment process because C buffers have no locks. Packed columns are immutable
  binaries and may cross processes/nodes.
- Columns support mixed types. Handle nulls, incompatible types and empty columns.
  Invalid NIF inputs raise `:badarg`; type mismatches in operations yield nil
  values; a failed NIF load exits `:nif_not_loaded`.

## Sizes and validation

- No per-layer value/string-byte cap exists; memory is the bound. Segment's soft
  byte budget keeps mutable segments near 64 MiB. Mutable columns can consume
  about twice their packed size.
- Strings and lists are limited to `2^31 - 1` bytes/items by packed `int32_t`
  lengths (`max_string_size/0`, `max_list_length/0`).
  Preserve `max_list_depth/0` (currently lists of lists).
- Row-count/capacity arguments (`new`, `pad`) are bounded at `2^40`; invalid
  capacities raise `:badarg`. This prevents size wrapping, not exhaustion:
  much smaller counts can exhaust memory and abort. Pass real row counts.
  `to_list` above `2^32 - 1` rows raises `:badarg`.
- Keep argument-derived sizes bounded before allocating, with checked arithmetic
  and checked allocation wrappers. Unrepresentable sizes or failed allocations
  abort with a message, never wrap.
- `append` and `from_list` validate the entire value before mutation and raise
  `:badarg` without changing the column on refusal. Values passed to them must
  never reach a C `assert`, which aborts the VM. Packed binaries remain trusted.
- A NIF copying list values gives its result all input nested layers and trims
  unused trailing layers (see `filter`); packing ends at the first layer without lists.

## Metadata and compatibility

- The eight-field metadata tuple order is fixed: count, null, false, true,
  integer, float, string, list counts. Min/max are separate; list_count is shallow.
  `Metadata.tuple/1` is a compile-time macro; omitted fields are wildcards,
  not a runtime tuple constructor for dynamic fields.
- Changing the layout requires updating the macro, add/subtract clauses, every
  pattern match, native metadata and the segment secondary header together.
  Adding a field is a breaking format change requiring a major version bump
  and a plan to migrate existing `.seg` files or invalidate the cache; follow
  the parent's explicit format-migration and golden-fixture rules.
- Metadata addition must be commutative: `Metadata.add(a, b) == Metadata.add(b, a)`
  because distributed schema aggregation has no fixed order.

## Tests

Cover empty, all-null and mixed-type columns, large datasets (10,000+ values)
and capacity boundaries. See `test/guardian/storage/column_test.exs` for examples.
Keep the NIF name/arity parity test passing when changing native operations.
