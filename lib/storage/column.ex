defmodule Storage.Column do
  alias Storage.Column.NIF

  def new do
    new(0)
  end

  defdelegate max_string_size, to: NIF
  defdelegate max_list_length, to: NIF
  defdelegate max_list_depth, to: NIF
  defdelegate new(capacity), to: NIF
  defdelegate pad(column, count), to: NIF
  defdelegate append(column, value), to: NIF

  @doc "Returns true if `value` can be appended to an empty column."
  defdelegate valid_value?(value), to: NIF, as: :valid_value
  defdelegate pack(column), to: NIF

  @doc """
  The size of `column` once packed, without packing it. For a packed column this is
  its `byte_size/1`.
  """
  defdelegate packed_size(column), to: NIF

  @doc """
  The bytes of a mutable column's buffers, across all of its layers. It leaves out the
  column's small fixed structs and allocator overhead.
  """
  defdelegate allocated_size(column), to: NIF

  @doc """
  The packed size of a column of `count` nils: its header and top-level bitmaps.

  Padding a column with nils adds exactly the growth of this size, so
  `packed_size(column) - nil_column_size(count(column))` does not change when the
  column is padded.
  """
  def nil_column_size(count) when is_integer(count) and count >= 0 do
    # A 72-byte header and seven bitmaps of one 64-bit word per 64 rows.
    72 + 7 * 8 * div(count + 63, 64)
  end

  defdelegate get_value(column, offset), to: NIF
  defdelegate from_list(column), to: NIF
  defdelegate to_list(column), to: NIF
  defdelegate count(column), to: NIF
  defdelegate null_count(column), to: NIF
  defdelegate false_count(column), to: NIF
  defdelegate true_count(column), to: NIF
  defdelegate int_count(column), to: NIF
  defdelegate float_count(column), to: NIF
  defdelegate string_count(column), to: NIF
  defdelegate metadata(column), to: NIF
  defdelegate filter(column1, column2), to: NIF
  defdelegate add(column1, column2), to: NIF
  defdelegate subtract(column1, column2), to: NIF
  defdelegate multiply(column1, column2), to: NIF
  defdelegate divide(column1, column2), to: NIF
  defdelegate and_oper(column1, column2), to: NIF
  defdelegate or_oper(column1, column2), to: NIF
  defdelegate not_oper(column1), to: NIF
  defdelegate min_max_number(column), to: NIF
  defdelegate number_to_false(column), to: NIF
  defdelegate number_to_true(column), to: NIF
  defdelegate to_boolean(column), to: NIF
  defdelegate to_string(column), to: NIF

  def from_list_slow(values) do
    capacity = length(values)
    column = new(capacity)

    Enum.each(values, fn value ->
      append(column, value)
    end)

    pack(column)
  end

  @doc """
  `column` cut or padded with nils to `count` rows, packed. A column already of that
  count is returned as it is. A mutable column is padded in place.
  """
  def resize(column, count) do
    case count(column) do
      ^count ->
        column

      # NIF.pad/2 grows only a mutable column; a packed one is rebuilt.
      other_count when other_count < count and is_binary(column) ->
        (to_list(column) ++ List.duplicate(nil, count - other_count)) |> from_list()

      other_count when other_count < count ->
        pad(column, count) |> pack()

      other_count when other_count > count ->
        # TODO: re-implement as NIF
        to_list(column) |> Enum.take(count) |> from_list()
    end
  end

  def duplicate(value, count) do
    column = new(count)
    duplicate(column, value, count)
  end

  defp duplicate(column, value, count) when count > 0 do
    append(column, value)
    duplicate(column, value, count - 1)
  end

  defp duplicate(column, _value, 0) do
    column
  end

  def generate(func, count) when is_function(func, 0) do
    column = new(count)

    if count > 0 do
      Enum.each(1..count, fn _ ->
        append(column, func.())
      end)
    end

    pack(column)
  end
end
