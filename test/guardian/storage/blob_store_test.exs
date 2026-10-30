defmodule Guardian.Storage.BlobStoreTest do
  use ExUnit.Case, async: true
  import Guardian.Storage.BlobStore

  @moduletag :tmp_dir

  # The write mechanism itself is tested in Guardian.AtomicFileTest.
  test "write replaces the file through the atomic writer", %{tmp_dir: dir} do
    filename = Path.join([dir, "sub", "events.seg"])

    assert :ok = write(filename, "first")
    assert :ok = write(filename, "second")

    assert File.read!(filename) == "second"
    assert File.ls!(Path.dirname(filename)) == ["events.seg"]
  end
end
