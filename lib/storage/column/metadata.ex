defmodule Storage.Column.Metadata do
  defmacro tuple(opts \\ []) do
    underscore =
      quote do
        _
      end

    {count, opts} = Keyword.pop_first(opts, :count, underscore)
    {null_count, opts} = Keyword.pop_first(opts, :null_count, underscore)
    {false_count, opts} = Keyword.pop_first(opts, :false_count, underscore)
    {true_count, opts} = Keyword.pop_first(opts, :true_count, underscore)
    {int_count, opts} = Keyword.pop_first(opts, :int_count, underscore)
    {float_count, opts} = Keyword.pop_first(opts, :float_count, underscore)
    {string_count, opts} = Keyword.pop_first(opts, :string_count, underscore)
    {list_count, opts} = Keyword.pop_first(opts, :list_count, underscore)
    [] = opts

    quote do
      {
        unquote(count),
        unquote(null_count),
        unquote(false_count),
        unquote(true_count),
        unquote(int_count),
        unquote(float_count),
        unquote(string_count),
        unquote(list_count)
      }
    end
  end

  def add([tuple1 | list1], [tuple2 | list2]) do
    [add(tuple1, tuple2) | add(list1, list2)]
  end

  def add([_ | _] = list, []) do
    list
  end

  def add([], [_ | _] = list) do
    list
  end

  def add([], []) do
    []
  end

  def add(
        tuple(
          count: count1,
          null_count: null_count1,
          false_count: false_count1,
          true_count: true_count1,
          int_count: int_count1,
          float_count: float_count1,
          string_count: string_count1,
          list_count: list_count1
        ),
        tuple(
          count: count2,
          null_count: null_count2,
          false_count: false_count2,
          true_count: true_count2,
          int_count: int_count2,
          float_count: float_count2,
          string_count: string_count2,
          list_count: list_count2
        )
      ) do
    tuple(
      count: count1 + count2,
      null_count: null_count1 + null_count2,
      false_count: false_count1 + false_count2,
      true_count: true_count1 + true_count2,
      int_count: int_count1 + int_count2,
      float_count: float_count1 + float_count2,
      string_count: string_count1 + string_count2,
      list_count: list_count1 + list_count2
    )
  end

  def subtract([tuple1 | list1], [tuple2 | list2]) do
    [subtract(tuple1, tuple2) | subtract(list1, list2)]
  end

  def subtract([_ | _] = list, []) do
    list
  end

  def subtract([], []) do
    []
  end

  def subtract(
        tuple(
          count: count1,
          null_count: null_count1,
          false_count: false_count1,
          true_count: true_count1,
          int_count: int_count1,
          float_count: float_count1,
          string_count: string_count1,
          list_count: list_count1
        ),
        tuple(
          count: count2,
          null_count: null_count2,
          false_count: false_count2,
          true_count: true_count2,
          int_count: int_count2,
          float_count: float_count2,
          string_count: string_count2,
          list_count: list_count2
        )
      ) do
    tuple(
      count: count1 - count2,
      null_count: null_count1 - null_count2,
      false_count: false_count1 - false_count2,
      true_count: true_count1 - true_count2,
      int_count: int_count1 - int_count2,
      float_count: float_count1 - float_count2,
      string_count: string_count1 - string_count2,
      list_count: list_count1 - list_count2
    )
  end
end
