defmodule Guardian.Storage.ValueTest do
  import Guardian.Storage.Value
  use ExUnit.Case, async: true

  test "limits" do
    assert max_string_size() == 2 ** 31 - 1
    assert max_list_length() == 2 ** 31 - 1
    assert max_list_depth() == 3
  end

  test "list depth" do
    assert valid?([]) == true
    assert valid?([[]]) == true
    assert valid?([[[]]]) == false
    assert valid?([[[[]]]]) == false
    assert valid?([[[[[]]]]]) == false

    assert valid?([1]) == true
    assert valid?([[1]]) == true
    assert valid?([[[1]]]) == false
    assert valid?([[[[1]]]]) == false
    assert valid?([[[[[1]]]]]) == false
  end

  test "list length" do
    assert valid?(List.duplicate(1, 70_000)) == true
    assert valid?([List.duplicate(1, 70_000)]) == true
  end

  test "matches what a column accepts" do
    assert valid?(%{"a" => 1}) == true
    assert valid?([%{"a" => 1}]) == false
    assert valid?(:atom) == false
    assert valid?(9_223_372_036_854_775_808) == false
    assert valid?(String.duplicate("a", 70_000)) == true
    assert valid?([List.duplicate(1, 40_000), List.duplicate(1, 40_000)]) == true
  end

  test "keys" do
    assert valid_key?(String.duplicate("k", max_key_size())) == true
    assert valid_key?(String.duplicate("k", max_key_size() + 1)) == false
  end
end
