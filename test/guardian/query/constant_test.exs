defmodule Guardian.Query.ConstantTest do
  alias Guardian.Query.Constant
  alias Guardian.Storage.Column.Metadata
  import Guardian.Query.Constant
  require Metadata
  use ExUnit.Case, async: true

  test "metadata" do
    assert metadata(%Constant{value: 5, count: 100}) == [
             Metadata.tuple(
               count: 100,
               null_count: 0,
               false_count: 0,
               true_count: 0,
               int_count: 100,
               float_count: 0,
               string_count: 0,
               list_count: 0
             ),
           ]

    assert metadata(%Constant{value: [], count: 100}) == [
             Metadata.tuple(
               count: 100,
               null_count: 0,
               false_count: 0,
               true_count: 0,
               int_count: 0,
               float_count: 0,
               string_count: 0,
               list_count: 100
             ),
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

    assert metadata(%Constant{value: [false, false, true], count: 100}) == [
             Metadata.tuple(
               count: 100,
               null_count: 0,
               false_count: 0,
               true_count: 0,
               int_count: 0,
               float_count: 0,
               string_count: 0,
               list_count: 100
             ),
             Metadata.tuple(
               count: 300,
               null_count: 0,
               false_count: 200,
               true_count: 100,
               int_count: 0,
               float_count: 0,
               string_count: 0,
               list_count: 0
             ),
           ]
  end
end
