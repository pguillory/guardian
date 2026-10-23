defmodule Storage.MmapTest do
  # Not async: the live-mapping counter and the open-descriptor count are global.
  use ExUnit.Case, async: false
  import TestHelpers, only: [eventually_after_gc: 1]

  alias Storage.Mmap

  @moduletag :tmp_dir

  # Other processes may map or open files while a test runs, so allow some slack. A
  # leak shows up as all @files.
  @files 50
  @slack 10

  test "reads a file's contents", %{tmp_dir: dir} do
    path = Path.join(dir, "data")
    contents = :crypto.strong_rand_bytes(100_000)
    File.write!(path, contents)

    assert {:ok, ^contents} = Mmap.read(path)
    assert {:ok, ^contents} = Mmap.read(String.to_charlist(path))
  end

  test "accepts a Unicode charlist path", %{tmp_dir: dir} do
    path = Path.join(dir, "é✓.data")
    File.write!(path, "unicode")

    assert Mmap.read(String.to_charlist(path)) == {:ok, "unicode"}
  end

  test "reads an empty file as an empty binary", %{tmp_dir: dir} do
    path = Path.join(dir, "empty")
    File.write!(path, "")

    assert Mmap.read(path) == {:ok, ""}
  end

  test "reports errors without leaking descriptors", %{tmp_dir: dir} do
    before = open_descriptors()

    for _ <- 1..@files do
      assert Mmap.read(Path.join(dir, "missing")) == {:error, :enoent}
      # A directory opens, then fails after the descriptor exists.
      assert Mmap.read(dir) == {:error, :eisdir}
    end

    assert open_descriptors() - before < @slack
  end

  test "rejects a path containing a NUL byte" do
    assert_raise ArgumentError, fn -> Mmap.read("a\0b") end
  end

  test "holds no descriptor while mapped and unmaps once unreferenced", %{tmp_dir: dir} do
    paths =
      for i <- 1..@files do
        path = Path.join(dir, "file#{i}")
        File.write!(path, String.duplicate("x", 10_000))
        path
      end

    mappings_before = Mmap.live_mappings()
    descriptors_before = open_descriptors()

    task =
      Task.async(fn ->
        binaries =
          Enum.map(paths, fn path ->
            {:ok, binary} = Mmap.read(path)
            binary
          end)

        Enum.each(paths, &File.rm!/1)

        # Deleted files stay readable while mapped.
        assert Enum.all?(binaries, &(&1 == String.duplicate("x", 10_000)))
        {Mmap.live_mappings(), open_descriptors(), length(binaries)}
      end)

    {mappings_during, descriptors_during, @files} = Task.await(task)
    assert mappings_during - mappings_before >= @files - @slack
    assert descriptors_during - descriptors_before < @slack

    # The task has exited, so nothing refers to its mappings.
    eventually_after_gc(fn -> Mmap.live_mappings() - mappings_before < @slack end)
  end

  test "a sub-binary keeps its mapping alive", %{tmp_dir: dir} do
    path = Path.join(dir, "data")
    contents = :crypto.strong_rand_bytes(10_000)
    File.write!(path, contents)
    expected = binary_part(contents, 2_000, 1_000)
    before = Mmap.live_mappings()
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        {:ok, binary} = Mmap.read(path)
        # Large enough to be sent as a reference to the mapped binary, not copied.
        send(parent, {:part, binary_part(binary, 2_000, 1_000)})
      end)

    assert_receive {:part, part}
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    File.rm!(path)
    Enum.each(Process.list(), &:erlang.garbage_collect/1)

    assert Mmap.live_mappings() - before >= 1
    assert part == expected
  end

  defp open_descriptors do
    # Both Linux and macOS list the calling process's descriptors here.
    dir = if File.dir?("/proc/self/fd"), do: "/proc/self/fd", else: "/dev/fd"
    dir |> File.ls!() |> length()
  end
end
