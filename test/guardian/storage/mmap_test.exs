defmodule Guardian.Storage.MmapTest do
  use ExUnit.Case, async: true
  import Guardian.Storage.Mmap

  @moduletag :tmp_dir

  test "reads a file's contents", %{tmp_dir: dir} do
    path = Path.join(dir, "data")
    contents = :crypto.strong_rand_bytes(100_000)
    File.write!(path, contents)

    assert {:ok, ^contents} = read(path)
    assert {:ok, ^contents} = read(String.to_charlist(path))
  end

  test "accepts a Unicode charlist path", %{tmp_dir: dir} do
    path = Path.join(dir, "é✓.data")
    File.write!(path, "unicode")

    assert read(String.to_charlist(path)) == {:ok, "unicode"}
  end

  test "reads an empty file as an empty binary", %{tmp_dir: dir} do
    path = Path.join(dir, "empty")
    File.write!(path, "")

    assert read(path) == {:ok, ""}
  end

  test "reports a missing file or a directory as an error", %{tmp_dir: dir} do
    assert read(Path.join(dir, "missing")) == {:error, :enoent}
    # A directory opens, then fails to map.
    assert read(dir) == {:error, :eisdir}
  end

  test "rejects a path containing a NUL byte" do
    assert_raise ArgumentError, fn -> read("a\0b") end
  end

  test "a mapped file stays readable after it is deleted", %{tmp_dir: dir} do
    path = Path.join(dir, "data")
    contents = :crypto.strong_rand_bytes(10_000)
    File.write!(path, contents)

    {:ok, binary} = read(path)
    File.rm!(path)

    assert binary == contents
  end

  test "a sub-binary keeps its mapping alive", %{tmp_dir: dir} do
    path = Path.join(dir, "data")
    contents = :crypto.strong_rand_bytes(10_000)
    File.write!(path, contents)
    expected = binary_part(contents, 2_000, 1_000)
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        {:ok, binary} = read(path)
        # Large enough to be sent as a reference to the mapped binary, not copied.
        send(parent, {:part, binary_part(binary, 2_000, 1_000)})
      end)

    assert_receive {:part, part}
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    File.rm!(path)
    :erlang.garbage_collect()

    assert part == expected
  end
end
