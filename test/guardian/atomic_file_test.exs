defmodule Guardian.AtomicFileTest do
  alias Guardian.AtomicFile
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  test "write replaces the file and leaves no temp file", %{tmp_dir: dir} do
    filename = Path.join([dir, "sub", "events.seg"])

    assert :ok = AtomicFile.write(filename, "first")
    assert :ok = AtomicFile.write(filename, ["sec", "ond"])

    assert File.read!(filename) == "second"
    assert File.ls!(Path.dirname(filename)) == ["events.seg"]
  end

  test "a failed write reports the error and leaves no temp file", %{tmp_dir: dir} do
    # Renaming a file over a nonempty directory fails after the temp file is written.
    filename = Path.join(dir, "taken")
    File.mkdir_p!(Path.join(filename, "child"))

    assert {:error, _reason} = AtomicFile.write(filename, "data")
    assert File.ls!(dir) == ["taken"]
  end

  test "data that cannot be written is an error and leaves no temp file", %{tmp_dir: dir} do
    filename = Path.join(dir, "events.seg")

    assert {:error, :badarg} = AtomicFile.write(filename, [:not_iodata])
    assert File.ls!(dir) == []
  end

  test "temp_file? matches exactly the temp names write creates" do
    assert AtomicFile.temp_file?("a.gsql.123.tmp")
    assert AtomicFile.temp_file?("_write.lock.1.tmp")

    for name <- ~w[a.tmp a.0.tmp a.01.tmp a.x.tmp a.1.tmp.bak tmp a.gsql] do
      refute AtomicFile.temp_file?(name), name
    end
  end
end
