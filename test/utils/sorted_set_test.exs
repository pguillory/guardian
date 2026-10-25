defmodule Guardian.SortedSetTest do
  import Guardian.SortedSet
  use ExUnit.Case, async: true

  test "union" do
    assert union(~w[a b d e], ~w[b c d]) == ~w[a b c d e]
    assert union(~w[b c d], ~w[a b d e]) == ~w[a b c d e]
  end

  test "diff" do
    assert diff(~w[a b c d e], ~w[b d]) == ~w[a c e]
  end
end
