defmodule UtilsTest do
  import Utils
  use ExUnit.Case, async: true

  test "simultaneously" do
    assert simultaneously([fn -> 1 end, fn -> 2 end]) == [1, 2]
  end
end
