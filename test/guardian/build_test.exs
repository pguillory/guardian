defmodule Guardian.BuildTest do
  import Guardian.Build
  use ExUnit.Case, async: true

  test "commit" do
    assert commit() == "unknown"
  end
end
