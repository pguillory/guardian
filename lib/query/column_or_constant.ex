defmodule Query.ColumnOrConstant do
  alias Query.Constant
  alias Storage.Column
  alias Storage.Column.Metadata
  require Metadata

  def column_or_constant_to_column(%Constant{value: value, count: count}) do
    Column.duplicate(value, count)
  end

  def column_or_constant_to_column(column) do
    column
  end

  # Where evaluated values become a column or constant: a value storage can't hold
  # (a list of lists of lists, an integer outside int64) becomes null, so no
  # expression yields one (Query.Numeric). Functions avoid producing them; this is the
  # backstop. Checking costs nothing on the usual path: Column.from_list validates
  # anyway, and only a failed list is scanned.
  def list_or_constant_to_column_or_constant(%Constant{value: value} = constant) do
    if Storage.Value.valid?(value), do: constant, else: %{constant | value: nil}
  end

  def list_or_constant_to_column_or_constant(list) when is_list(list) do
    column =
      try do
        Column.from_list(list)
      rescue
        ArgumentError ->
          list |> Enum.map(&if(Storage.Value.valid?(&1), do: &1, else: nil)) |> Column.from_list()
      end

    column_to_column_or_constant(column)
  end

  def column_to_column_or_constant(column) do
    case Column.metadata(column) do
      [Metadata.tuple(null_count: count, count: count) | _] ->
        Constant.duplicate(nil, count)

      [Metadata.tuple(false_count: count, count: count) | _] ->
        Constant.duplicate(false, count)

      [Metadata.tuple(true_count: count, count: count) | _] ->
        Constant.duplicate(true, count)

      [Metadata.tuple(count: 1) | _] ->
        [value] = Column.to_list(column)
        Constant.duplicate(value, 1)

      [Metadata.tuple() | _] ->
        column
    end
  end

  def generate(func, count) when is_function(func, 0) do
    Column.generate(func, count)
    |> column_to_column_or_constant()
  end

  def count(%Constant{} = constant) do
    Constant.count(constant)
  end

  def count(column) do
    Column.count(column)
  end

  def metadata(%Constant{} = constant) do
    Constant.metadata(constant)
  end

  def metadata(column) do
    Column.metadata(column)
  end

  def min_max_number(%Constant{} = constant) do
    Constant.min_max_number(constant)
  end

  def min_max_number(column) do
    Column.min_max_number(column)
  end

  def number_to_false(%Constant{} = constant) do
    Constant.number_to_false(constant)
  end

  def number_to_false(column) do
    Column.number_to_false(column)
  end

  def number_to_true(%Constant{} = constant) do
    Constant.number_to_true(constant)
  end

  def number_to_true(column) do
    Column.number_to_true(column)
  end

  defp map_to_list_or_constant(%Constant{value: value1, count: count}, func)
       when is_function(func, 1) do
    # Constant.map(constant, func)
    %Constant{value: func.(value1), count: count}
  end

  defp map_to_list_or_constant(column1, func) when is_function(func, 1) do
    list1 = Column.to_list(column1)
    SuperList.map(list1, func)
  end

  defp map_to_list_or_constant(%Constant{value: value1, count: count}, column2, func)
       when is_function(func, 2) do
    ^count = count(column2)
    map_to_list_or_constant(column2, &func.(value1, &1))
  end

  defp map_to_list_or_constant(column1, %Constant{value: value2, count: count}, func)
       when is_function(func, 2) do
    ^count = count(column1)
    map_to_list_or_constant(column1, &func.(&1, value2))
  end

  defp map_to_list_or_constant(column1, column2, func) when is_function(func, 2) do
    list1 = Column.to_list(column1)
    list2 = Column.to_list(column2)
    SuperList.map(list1, list2, func)
  end

  defp map_to_list_or_constant(%Constant{value: value1, count: count}, column2, column3, func)
       when is_function(func, 3) do
    ^count = count(column2)
    ^count = count(column3)
    map_to_list_or_constant(column2, column3, &func.(value1, &1, &2))
  end

  defp map_to_list_or_constant(column1, %Constant{value: value2, count: count}, column3, func)
       when is_function(func, 3) do
    ^count = count(column1)
    ^count = count(column3)
    map_to_list_or_constant(column1, column3, &func.(&1, value2, &2))
  end

  defp map_to_list_or_constant(column1, column2, %Constant{value: value3, count: count}, func)
       when is_function(func, 3) do
    ^count = count(column1)
    ^count = count(column2)
    map_to_list_or_constant(column1, column2, &func.(&1, &2, value3))
  end

  defp map_to_list_or_constant(column1, column2, column3, func) when is_function(func, 3) do
    list1 = Column.to_list(column1)
    list2 = Column.to_list(column2)
    list3 = Column.to_list(column3)
    SuperList.map(list1, list2, list3, func)
  end

  defp map_to_list_or_constant(
         %Constant{value: value1, count: count},
         column2,
         column3,
         column4,
         func
       )
       when is_function(func, 4) do
    ^count = count(column2)
    ^count = count(column3)
    ^count = count(column4)
    map_to_list_or_constant(column2, column3, column4, &func.(value1, &1, &2, &3))
  end

  defp map_to_list_or_constant(
         column1,
         %Constant{value: value2, count: count},
         column3,
         column4,
         func
       )
       when is_function(func, 4) do
    ^count = count(column1)
    ^count = count(column3)
    ^count = count(column4)
    map_to_list_or_constant(column1, column3, column4, &func.(&1, value2, &2, &3))
  end

  defp map_to_list_or_constant(
         column1,
         column2,
         %Constant{value: value3, count: count},
         column4,
         func
       )
       when is_function(func, 4) do
    ^count = count(column1)
    ^count = count(column2)
    ^count = count(column4)
    map_to_list_or_constant(column1, column2, column4, &func.(&1, &2, value3, &3))
  end

  defp map_to_list_or_constant(
         column1,
         column2,
         column3,
         %Constant{value: value4, count: count},
         func
       )
       when is_function(func, 4) do
    ^count = count(column1)
    ^count = count(column2)
    ^count = count(column3)
    map_to_list_or_constant(column1, column2, column3, &func.(&1, &2, &3, value4))
  end

  defp map_to_list_or_constant(column1, column2, column3, column4, func)
       when is_function(func, 4) do
    list1 = Column.to_list(column1)
    list2 = Column.to_list(column2)
    list3 = Column.to_list(column3)
    list4 = Column.to_list(column4)
    SuperList.map(list1, list2, list3, list4, func)
  end

  def map(column1, map_func) do
    map_to_list_or_constant(column1, map_func)
    |> list_or_constant_to_column_or_constant()
  end

  def map(column1, column2, map_func) do
    map_to_list_or_constant(column1, column2, map_func)
    |> list_or_constant_to_column_or_constant()
  end

  def map(column1, column2, column3, map_func) do
    map_to_list_or_constant(column1, column2, column3, map_func)
    |> list_or_constant_to_column_or_constant()
  end

  def map(column1, column2, column3, column4, map_func) do
    map_to_list_or_constant(column1, column2, column3, column4, map_func)
    |> list_or_constant_to_column_or_constant()
  end

  defp n_to_list_or_constant([%Constant{value: value1, count: count}]) do
    %Constant{value: [value1], count: count}
  end

  defp n_to_list_or_constant([column1]) do
    list1 = Column.to_list(column1)
    SuperList.map(list1, &[&1])
  end

  defp n_to_list_or_constant([%Constant{value: value1, count: count} | columns]) do
    case n_to_list_or_constant(columns) do
      %Constant{value: values, count: ^count} ->
        %Constant{value: [value1 | values], count: count}

      list2 when is_list(list2) ->
        SuperList.map(list2, &[value1 | &1])
    end
  end

  defp n_to_list_or_constant([column1 | columns]) do
    list1 = Column.to_list(column1)

    case n_to_list_or_constant(columns) do
      %Constant{value: values} ->
        SuperList.map(list1, &[&1 | values])

      list2 when is_list(list2) ->
        SuperList.map(list1, list2, &[&1 | &2])
    end
  end

  def map_n(columns) do
    n_to_list_or_constant(columns)
    |> list_or_constant_to_column_or_constant()
  end

  # `func` takes the list of a row's values, one per column.
  def map_n(columns, func) do
    case n_to_list_or_constant(columns) do
      %Constant{value: values} = constant -> %Constant{constant | value: func.(values)}
      rows -> SuperList.map(rows, func)
    end
    |> list_or_constant_to_column_or_constant()
  end

  def map_or_nif(%Constant{} = constant1, map_func, nif_func)
      when is_function(map_func, 1) and is_function(nif_func, 1) do
    map(constant1, map_func)
  end

  def map_or_nif(column1, map_func, nif_func)
      when is_function(map_func, 1) and is_function(nif_func, 1) do
    nif_func.(column1)
    |> column_to_column_or_constant()
  end

  def map_or_nif(%Constant{} = constant1, column2, map_func, nif_func)
      when is_function(map_func, 2) and is_function(nif_func, 2) do
    map(constant1, column2, map_func)
  end

  def map_or_nif(column1, %Constant{} = constant2, map_func, nif_func)
      when is_function(map_func, 2) and is_function(nif_func, 2) do
    map(column1, constant2, map_func)
  end

  def map_or_nif(column1, column2, map_func, nif_func)
      when is_function(map_func, 2) and is_function(nif_func, 2) do
    nif_func.(column1, column2)
    |> column_to_column_or_constant()
  end

  def map_or_nif(%Constant{} = constant1, column2, column3, map_func, nif_func)
      when is_function(map_func, 3) and is_function(nif_func, 3) do
    map(constant1, column2, column3, map_func)
  end

  def map_or_nif(column1, %Constant{} = constant2, column3, map_func, nif_func)
      when is_function(map_func, 3) and is_function(nif_func, 3) do
    map(column1, constant2, column3, map_func)
  end

  def map_or_nif(column1, column2, %Constant{} = constant3, map_func, nif_func)
      when is_function(map_func, 3) and is_function(nif_func, 3) do
    map(column1, column2, constant3, map_func)
  end

  def map_or_nif(column1, column2, column3, map_func, nif_func)
      when is_function(map_func, 3) and is_function(nif_func, 3) do
    nif_func.(column1, column2, column3)
    |> column_to_column_or_constant()
  end
end
