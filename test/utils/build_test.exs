defmodule BuildTest do
  import Build
  use ExUnit.Case, async: true

  test "commit" do
    assert commit() == "unknown"
  end
end
