defmodule Guardian.Storage.BlobStoreTest do
  alias Guardian.Storage.BlobStore
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  # The write mechanism itself is tested in Guardian.AtomicFileTest.
  test "write replaces the file through the atomic writer", %{tmp_dir: dir} do
    filename = Path.join([dir, "sub", "events.seg"])

    assert :ok = BlobStore.write(filename, "first")
    assert :ok = BlobStore.write(filename, "second")

    assert File.read!(filename) == "second"
    assert File.ls!(Path.dirname(filename)) == ["events.seg"]
  end
end
