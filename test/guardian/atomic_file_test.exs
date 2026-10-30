defmodule Guardian.AtomicFileTest do
  use ExUnit.Case, async: true
  import Guardian.AtomicFile

  @moduletag :tmp_dir

  test "write replaces the file and leaves no temp file", %{tmp_dir: dir} do
    filename = Path.join([dir, "sub", "events.seg"])

    assert :ok = write(filename, "first")
    assert :ok = write(filename, ["sec", "ond"])

    assert File.read!(filename) == "second"
    assert File.ls!(Path.dirname(filename)) == ["events.seg"]
  end

  test "a failed write reports the error and leaves no temp file", %{tmp_dir: dir} do
    # Renaming a file over a nonempty directory fails after the temp file is written.
    filename = Path.join(dir, "taken")
    File.mkdir_p!(Path.join(filename, "child"))

    assert {:error, _reason} = write(filename, "data")
    assert File.ls!(dir) == ["taken"]
  end

  test "data that cannot be written is an error and leaves no temp file", %{tmp_dir: dir} do
    filename = Path.join(dir, "events.seg")

    assert {:error, :badarg} = write(filename, [:not_iodata])
    assert File.ls!(dir) == []
  end

  test "temp_file? matches exactly the temp names write creates" do
    assert temp_file?("a.gsql.123.tmp")
    assert temp_file?("_write.lock.1.tmp")

    for name <- ~w[a.tmp a.0.tmp a.01.tmp a.x.tmp a.1.tmp.bak tmp a.gsql] do
      refute temp_file?(name), name
    end
  end
end
