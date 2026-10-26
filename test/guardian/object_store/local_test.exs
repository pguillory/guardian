defmodule Guardian.ObjectStore.LocalTest do
  use ExUnit.Case, async: true

  alias Guardian.ObjectStore

  setup do
    dir = Path.join(System.tmp_dir!(), "object_store_local_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, store} = ObjectStore.Local.new(dir)
    %{dir: dir, store: store}
  end

  defp keys(store) do
    {:ok, objects} = ObjectStore.list(store)
    Enum.map(objects, & &1.key)
  end

  defp write!(dir, key, body \\ "x") do
    path = Path.join(dir, key)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
  end

  test "lists every regular file at any depth, skipping hidden, temporary and folders", %{
    dir: dir,
    store: store,
  } do
    for key <- ~w[top a/b.txt a/b/c/d.gsql t/a.gsql README] do
      write!(dir, key)
    end

    # Hidden names, files or folders, and a temp file left by a crash mid-write.
    for key <- ~w[.DS_Store t/.a.gsql .git/config t/.hidden/x.gsql t/a.gsql.123.tmp] do
      write!(dir, key)
    end

    File.mkdir_p!(Path.join(dir, "t/folder.gsql"))
    assert keys(store) == ~w[README a/b.txt a/b/c/d.gsql t/a.gsql top]
  end

  test "an object's ETag and size are its content's, matching get", %{dir: dir, store: store} do
    body = :binary.copy("0123456789", 20_000)
    write!(dir, "big", body)
    assert {:ok, [%{key: "big", etag: etag, size: 200_000}]} = ObjectStore.list(store)
    assert {:ok, ^body, %{etag: ^etag}} = ObjectStore.get(store, "big")
    assert {:ok, ^etag} = ObjectStore.put(store, "big2", body, :none)
  end

  test "skips names that are not valid UTF-8 and lists ordinary Unicode", %{
    dir: dir,
    store: store,
  } do
    write!(dir, "café/ü.txt")
    # macOS refuses such a name (eilseq); Linux may have one.
    _ = File.write(Path.join(dir, <<"bad", 0xFF>>), "x")
    # With latin-1 file name encoding it lists as valid UTF-8 instead; either way no
    # key is invalid UTF-8.
    assert "café/ü.txt" in keys(store)
    assert Enum.all?(keys(store), &String.valid?/1)
    assert {:ok, "x", _meta} = ObjectStore.get(store, "café/ü.txt")
  end

  test "follows symlinked files and folders, skipping links back up the tree, dangling or looping",
       %{
         dir: dir,
         store: store,
       } do
    other = dir <> "_other"
    on_exit(fn -> File.rm_rf!(other) end)
    write!(other, "f.txt", "outside")
    write!(dir, "t/a.gsql")
    File.ln_s!(Path.join(other, "f.txt"), Path.join(dir, "link.txt"))
    File.ln_s!(other, Path.join(dir, "linked"))
    File.ln_s!(dir, Path.join(dir, "t/loop"))
    File.ln_s!(Path.join(dir, "missing"), Path.join(dir, "dangling"))
    File.ln_s!(Path.join(dir, "self"), Path.join(dir, "self"))

    assert keys(store) == ~w[link.txt linked/f.txt t/a.gsql]
  end

  test "fails a listing past max_entries", %{dir: dir} do
    {:ok, store} = ObjectStore.Local.new(dir, max_entries: 3)
    write!(dir, "a/b")
    write!(dir, "c")
    assert {:ok, [_, _]} = ObjectStore.list(store)

    write!(dir, "d")
    assert ObjectStore.list(store) == {:error, {:failed, "too many objects"}}
  end

  test "fails a listing on an unreadable file or folder", %{dir: dir, store: store} do
    write!(dir, "t/a.txt")
    path = Path.join(dir, "t/a.txt")
    File.chmod!(path, 0o000)
    on_exit(fn -> File.chmod(path, 0o644) end)
    assert ObjectStore.list(store) == {:error, {:failed, "t/a.txt: eacces"}}

    File.chmod!(path, 0o644)
    folder = Path.join(dir, "t")
    File.chmod!(folder, 0o000)
    on_exit(fn -> File.chmod(folder, 0o755) end)
    assert ObjectStore.list(store) == {:error, {:failed, "t: eacces"}}
  end

  test "a missing folder is misconfigured", %{dir: dir, store: store} do
    File.rm_rf!(dir)
    assert {:error, {:misconfigured, _}} = ObjectStore.list(store)
  end

  test "refuses unsafe keys on every operation without touching the disk", %{
    dir: dir,
    store: store,
  } do
    unsafe = [
      "",
      "/etc/passwd",
      "a//b",
      "a/",
      ".",
      "..",
      "a/../../x",
      "./a",
      ".hidden",
      "t/.a.gsql",
      "a\0b",
      "t/a.gsql.12.tmp",
      <<"bad", 0xFF>>,
    ]

    for key <- unsafe do
      assert ObjectStore.put(store, key, "x", :none) == {:error, {:failed, "invalid key"}}
      assert ObjectStore.get(store, key) == {:error, {:failed, "invalid key"}}
      assert ObjectStore.delete(store, key) == {:error, {:failed, "invalid key"}}
    end

    assert File.ls!(dir) == []
    refute File.exists?(Path.join(Path.dirname(dir), "x"))
  end

  test "keys that merely look like temp files are ordinary", %{store: store} do
    for key <- ~w[a.tmp a.0.tmp a.x.tmp tmp] do
      assert {:ok, _} = ObjectStore.put(store, key, "x", :none)
    end

    assert keys(store) == ~w[a.0.tmp a.tmp a.x.tmp tmp]
  end

  test "writes replace the file and leave no temp file, even when they fail", %{
    dir: dir,
    store: store,
  } do
    {:ok, etag1} = ObjectStore.put(store, "t/a.gsql", "SET a = 1", :absent)
    {:ok, _} = ObjectStore.put(store, "t/a.gsql", "SET a = 2", {:etag, etag1})
    assert File.read!(Path.join(dir, "t/a.gsql")) == "SET a = 2"
    assert File.ls!(Path.join(dir, "t")) == ["a.gsql"]

    # Renaming over a nonempty folder fails after the temp file is written.
    File.mkdir_p!(Path.join(dir, "u/b.gsql/child"))
    assert {:error, {:failed, _posix}} = ObjectStore.put(store, "u/b.gsql", "SET b = 1", :none)
    assert File.ls!(Path.join(dir, "u")) == ["b.gsql"]
  end

  test "concurrent :absent puts to one key: exactly one succeeds", %{dir: dir, store: store} do
    race_absent_puts(dir, [store])
  end

  test "stores naming one folder differently share its write lock", %{dir: dir, store: store} do
    link = dir <> "_link"
    File.ln_s!(dir, link)
    on_exit(fn -> File.rm(link) end)
    # A genuinely relative path: up from the working directory to the root, then down.
    up = File.cwd!() |> Path.split() |> tl() |> Enum.map(fn _ -> ".." end)
    relative = Path.join(up ++ [Path.relative(dir)])
    assert Path.type(relative) == :relative

    aliases =
      for name <- [dir <> "/", link, relative] do
        {:ok, alias_store} = ObjectStore.Local.new(name)
        alias_store
      end

    stores = [store | aliases]

    assert [_one_lock] =
             stores |> Enum.map(fn {_module, config} -> config.lock end) |> Enum.uniq()

    race_absent_puts(dir, stores)

    {:ok, {_module, other}} = ObjectStore.Local.new(dir <> "_other")
    on_exit(fn -> File.rm_rf!(dir <> "_other") end)
    assert other.lock != elem(store, 1).lock
  end

  # Each key gets several writers, through `stores` in turn, released at once; without
  # serialization they all see no file and all write.
  defp race_absent_puts(dir, stores) do
    writers = stores |> Stream.cycle() |> Enum.take(4 * length(stores)) |> Enum.with_index(1)

    tasks =
      for key <- ~w[k0 k1 k2 k3 k4], {store, n} <- writers do
        Task.async(fn ->
          receive do
            :go -> {key, n, ObjectStore.put(store, key, "#{n}", :absent)}
          end
        end)
      end

    Enum.each(tasks, &send(&1.pid, :go))
    results = Task.await_many(tasks, 30_000)

    for {key, key_results} <- Enum.group_by(results, &elem(&1, 0)) do
      {wins, losses} = Enum.split_with(key_results, &match?({_key, _n, {:ok, _}}, &1))
      assert [{^key, winner, {:ok, _etag}}] = wins
      assert Enum.all?(losses, &match?({^key, _n, {:error, :precondition_failed}}, &1))
      assert File.read!(Path.join(dir, key)) == "#{winner}"
    end
  end
end
