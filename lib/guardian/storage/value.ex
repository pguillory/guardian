defmodule Guardian.Storage.Value do
  @moduledoc """
  Rules for values that Storage can hold.

  Validity is decided by the column NIF itself, so these rules cannot drift from what
  a column accepts. Maps are always valid here because Storage flattens them into
  separate columns before storing; the flattened values are validated again.
  """

  alias Guardian.Storage.Column

  # The limits below come from the NIF at compile time, so recompile when it changes.
  @external_resource "src/column.c"
  @max_string_size Column.max_string_size()
  @max_list_length Column.max_list_length()
  @max_list_depth Column.max_list_depth()
  @max_key_size 250

  true = @max_list_depth > 1

  def max_string_size do
    @max_string_size
  end

  def max_list_length do
    @max_list_length
  end

  def max_list_depth do
    @max_list_depth
  end

  def max_key_size do
    @max_key_size
  end

  def valid_key?(key) when is_binary(key), do: byte_size(key) <= @max_key_size
  def valid_key?(_key), do: false

  def valid?(value) when is_map(value), do: true
  def valid?(value), do: Column.valid_value?(value)

  def validate(value) do
    true = valid?(value)
    value
  end
end
