defmodule Guardian.Query.NativeDispatch do
  @moduledoc """
  Scalar/native selection for native-backed query operations: arithmetic, boolean
  operations, `to_boolean` and `to_string`.

  Callers identify the operation and supply its scalar callback; native callbacks
  and eligibility live here, on top of `Guardian.Query.ColumnOrConstant`'s
  representation layer. Constants always use the scalar callback. Scalar semantics
  stay with the caller. A new native-backed operation gets its own `evaluate`
  clause here rather than a constant-or-native helper of its own. Unknown
  operations fail loudly.
  """

  alias Guardian.Query.ColumnOrConstant
  alias Guardian.Query.Constant
  alias Guardian.Storage.Column
  alias Guardian.Storage.Column.Metadata
  require Metadata

  @doc """
  Evaluates a unary operation using its scalar callback or eligible native path.
  """
  def evaluate(:to_string, column, map_func) do
    # Only strings and nulls can bypass the capped scalar renderer. A constant is
    # evaluated once by native_or_scalar, even if its value needs rendering.
    if match?(%Constant{}, column) or
         Column.null_count(column) + Column.string_count(column) == Column.count(column) do
      native_or_scalar(column, map_func, &Column.to_string/1)
    else
      ColumnOrConstant.map(column, map_func)
    end
  end

  def evaluate(:to_boolean, column, map_func) do
    native_or_scalar(column, map_func, &Column.to_boolean/1)
  end

  def evaluate(:not, column, map_func) do
    native_or_scalar(column, map_func, &Column.not_oper/1)
  end

  @doc """
  Evaluates a binary operation on already evaluated operands. Any constant keeps
  the scalar path. Timestamp arithmetic also needs scalar evaluation: the native
  arithmetic functions accept numbers only. Addition permits either direction;
  subtraction permits a timestamp only on the left.
  """
  def evaluate(:add, column1, column2, map_func) do
    if timestamp_and_seconds?(column1, column2) or timestamp_and_seconds?(column2, column1) do
      ColumnOrConstant.map(column1, column2, map_func)
    else
      native_or_scalar(column1, column2, map_func, &Column.add/2)
    end
  end

  def evaluate(:subtract, column1, column2, map_func) do
    if timestamp_and_seconds?(column1, column2) do
      ColumnOrConstant.map(column1, column2, map_func)
    else
      native_or_scalar(column1, column2, map_func, &Column.subtract/2)
    end
  end

  def evaluate(:multiply, column1, column2, map_func) do
    native_or_scalar(column1, column2, map_func, &Column.multiply/2)
  end

  def evaluate(:divide, column1, column2, map_func) do
    native_or_scalar(column1, column2, map_func, &Column.divide/2)
  end

  def evaluate(:and, column1, column2, map_func) do
    native_or_scalar(column1, column2, map_func, &Column.and_oper/2)
  end

  def evaluate(:or, column1, column2, map_func) do
    native_or_scalar(column1, column2, map_func, &Column.or_oper/2)
  end

  defp timestamp_and_seconds?(strings, ints) do
    holds?(strings, :string) and holds?(ints, :integer)
  end

  # Whether a column or constant holds at least one value of `type` at its top
  # level, from its metadata.
  defp holds?(column_or_constant, :string) do
    match?(
      [Metadata.tuple(string_count: n) | _] when n > 0,
      ColumnOrConstant.metadata(column_or_constant)
    )
  end

  defp holds?(column_or_constant, :integer) do
    match?(
      [Metadata.tuple(int_count: n) | _] when n > 0,
      ColumnOrConstant.metadata(column_or_constant)
    )
  end

  defp native_or_scalar(%Constant{} = constant1, map_func, nif_func)
       when is_function(map_func, 1) and is_function(nif_func, 1) do
    ColumnOrConstant.map(constant1, map_func)
  end

  defp native_or_scalar(column1, map_func, nif_func)
       when is_function(map_func, 1) and is_function(nif_func, 1) do
    nif_func.(column1)
    |> ColumnOrConstant.column_to_column_or_constant()
  end

  defp native_or_scalar(%Constant{} = constant1, column2, map_func, nif_func)
       when is_function(map_func, 2) and is_function(nif_func, 2) do
    ColumnOrConstant.map(constant1, column2, map_func)
  end

  defp native_or_scalar(column1, %Constant{} = constant2, map_func, nif_func)
       when is_function(map_func, 2) and is_function(nif_func, 2) do
    ColumnOrConstant.map(column1, constant2, map_func)
  end

  defp native_or_scalar(column1, column2, map_func, nif_func)
       when is_function(map_func, 2) and is_function(nif_func, 2) do
    nif_func.(column1, column2)
    |> ColumnOrConstant.column_to_column_or_constant()
  end
end
