defmodule Guardian.Query.Constant do
  alias Guardian.Storage.Column.Metadata
  alias Guardian.Storage.Value
  require Metadata

  @enforce_keys [:value, :count]
  defstruct [:value, :count]

  def duplicate(value, count) when is_integer(count) and count >= 0 do
    true = Value.valid?(value)
    %__MODULE__{value: value, count: count}
  end

  def count(%__MODULE__{count: count}) do
    count
  end

  def metadata(%__MODULE__{value: nil, count: count}) do
    [
      Metadata.tuple(
        count: count,
        null_count: count,
        false_count: 0,
        true_count: 0,
        int_count: 0,
        float_count: 0,
        string_count: 0,
        list_count: 0
      ),
    ]
  end

  def metadata(%__MODULE__{value: false, count: count}) do
    [
      Metadata.tuple(
        count: count,
        null_count: 0,
        false_count: count,
        true_count: 0,
        int_count: 0,
        float_count: 0,
        string_count: 0,
        list_count: 0
      ),
    ]
  end

  def metadata(%__MODULE__{value: true, count: count}) do
    [
      Metadata.tuple(
        count: count,
        null_count: 0,
        false_count: 0,
        true_count: count,
        int_count: 0,
        float_count: 0,
        string_count: 0,
        list_count: 0
      ),
    ]
  end

  def metadata(%__MODULE__{value: value, count: count}) when is_integer(value) do
    [
      Metadata.tuple(
        count: count,
        null_count: 0,
        false_count: 0,
        true_count: 0,
        int_count: count,
        float_count: 0,
        string_count: 0,
        list_count: 0
      ),
    ]
  end

  def metadata(%__MODULE__{value: value, count: count}) when is_float(value) do
    [
      Metadata.tuple(
        count: count,
        null_count: 0,
        false_count: 0,
        true_count: 0,
        int_count: 0,
        float_count: count,
        string_count: 0,
        list_count: 0
      ),
    ]
  end

  def metadata(%__MODULE__{value: value, count: count}) when is_binary(value) do
    [
      Metadata.tuple(
        count: count,
        null_count: 0,
        false_count: 0,
        true_count: 0,
        int_count: 0,
        float_count: 0,
        string_count: count,
        list_count: 0
      ),
    ]
  end

  @zero_count_metadata [
    Metadata.tuple(
      count: 0,
      null_count: 0,
      false_count: 0,
      true_count: 0,
      int_count: 0,
      float_count: 0,
      string_count: 0,
      list_count: 0
    ),
  ]

  def metadata(%__MODULE__{value: value, count: count}) when is_list(value) do
    [
      Metadata.tuple(
        count: count,
        null_count: 0,
        false_count: 0,
        true_count: 0,
        int_count: 0,
        float_count: 0,
        string_count: 0,
        list_count: count
      )
      | value
        |> Enum.map(&metadata(%__MODULE__{value: &1, count: count}))
        |> Enum.reduce(@zero_count_metadata, &Metadata.add/2),
    ]
  end

  def min_max_number(%__MODULE__{value: value}) do
    if is_number(value) do
      {value, value}
    else
      {nil, nil}
    end
  end

  def number_to_false(%__MODULE__{value: value, count: count}) do
    if is_number(value) do
      %__MODULE__{value: false, count: count}
    else
      %__MODULE__{value: nil, count: count}
    end
  end

  def number_to_true(%__MODULE__{value: value, count: count}) do
    if is_number(value) do
      %__MODULE__{value: true, count: count}
    else
      %__MODULE__{value: nil, count: count}
    end
  end
end
