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

  test "list, get, conditional put and delete", %{store: store} do
    assert ObjectStore.list(store) == {:ok, []}
    assert {:ok, etag1} = ObjectStore.put(store, "t/a.gsql", "SET a = 1", :absent)

    assert ObjectStore.put(store, "t/a.gsql", "SET a = 2", :absent) ==
             {:error, :precondition_failed}

    assert ObjectStore.put(store, "t/a.gsql", "SET a = 2", {:etag, "nope"}) ==
             {:error, :precondition_failed}

    assert {:ok, etag2} = ObjectStore.put(store, "t/a.gsql", "SET a = 2", {:etag, etag1})
    assert {:ok, _} = ObjectStore.put(store, "u/b.gsql", "SET b = 1", :none)
    assert {:ok, _} = ObjectStore.put(store, "v/c.gsql", "SET c = 1", :none)

    assert {:ok, objects} = ObjectStore.list(store)
    assert Enum.map(objects, & &1.key) == ["t/a.gsql", "u/b.gsql", "v/c.gsql"]
    assert %{etag: ^etag2, size: 9} = hd(objects)

    assert {:ok, "SET a = 2", %{etag: ^etag2, age_ms: age}} =
             ObjectStore.get(store, "t/a.gsql", etag2)

    assert age >= 0 and age < 5_000
    assert ObjectStore.get(store, "t/a.gsql", etag1) == {:error, :precondition_failed}
    assert ObjectStore.get(store, "t/missing.gsql") == {:error, :not_found}

    assert ObjectStore.delete(store, "u/b.gsql") == :ok
    assert ObjectStore.delete(store, "u/b.gsql") == :ok
    assert {:ok, [_, _]} = ObjectStore.list(store)
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
    assert ObjectStore.list(store) == {:error, "too many objects"}
  end

  test "fails a listing on an unreadable file or folder", %{dir: dir, store: store} do
    write!(dir, "t/a.txt")
    path = Path.join(dir, "t/a.txt")
    File.chmod!(path, 0o000)
    on_exit(fn -> File.chmod(path, 0o644) end)
    assert ObjectStore.list(store) == {:error, "t/a.txt: eacces"}

    File.chmod!(path, 0o644)
    folder = Path.join(dir, "t")
    File.chmod!(folder, 0o000)
    on_exit(fn -> File.chmod(folder, 0o755) end)
    assert ObjectStore.list(store) == {:error, "t: eacces"}
  end

  test "a missing folder is an error", %{dir: dir, store: store} do
    File.rm_rf!(dir)
    assert {:error, "#{dir} is not a folder"} == ObjectStore.list(store)
  end

  test "refuses unsafe keys on every operation", %{store: store} do
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
      assert ObjectStore.put(store, key, "x", :none) == {:error, "invalid key"}
      assert ObjectStore.get(store, key) == {:error, "invalid key"}
      assert ObjectStore.delete(store, key) == {:error, "invalid key"}
    end

    assert keys(store) == []
  end

  test "keys that merely look like temp files are ordinary", %{store: store} do
    for key <- ~w[a.tmp a.0.tmp a.x.tmp tmp] do
      assert {:ok, _} = ObjectStore.put(store, key, "x", :none)
    end

    assert keys(store) == ~w[a.0.tmp a.tmp a.x.tmp tmp]
  end

  test "a failed write is an error and stores nothing", %{dir: dir, store: store} do
    # Renaming over a nonempty folder fails after the temp file is written.
    File.mkdir_p!(Path.join(dir, "u/b.gsql/child"))
    assert {:error, _posix} = ObjectStore.put(store, "u/b.gsql", "SET b = 1", :none)
    assert keys(store) == []
  end

  test "concurrent :absent puts to one key: exactly one succeeds", %{store: store} do
    race_puts([store])
  end

  test "concurrent ETag puts: exactly one replaces each original", %{store: store} do
    etags =
      Map.new(~w[k0 k1 k2 k3 k4], fn key ->
        {:ok, etag} = ObjectStore.put(store, key, "original:#{key}", :absent)
        {key, etag}
      end)

    race_puts([store], fn key -> {:etag, Map.fetch!(etags, key)} end)
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

    race_puts([store | aliases])
  end

  # Each key gets several writers, through `stores` in turn, released at once; without
  # serialization several can read the same current version and all write.
  defp race_puts(stores, condition_for_key \\ fn _key -> :absent end) do
    writers = stores |> Stream.cycle() |> Enum.take(4 * length(stores)) |> Enum.with_index(1)

    tasks =
      for key <- ~w[k0 k1 k2 k3 k4], {store, n} <- writers do
        Task.async(fn ->
          receive do
            :go ->
              body = "#{key}:#{n}"
              {key, body, ObjectStore.put(store, key, body, condition_for_key.(key))}
          end
        end)
      end

    Enum.each(tasks, &send(&1.pid, :go))
    results = Task.await_many(tasks, 30_000)

    for {key, key_results} <- Enum.group_by(results, &elem(&1, 0)) do
      {wins, losses} = Enum.split_with(key_results, &match?({_key, _body, {:ok, _}}, &1))
      assert [{^key, winner, {:ok, etag}}] = wins
      assert Enum.all?(losses, &match?({^key, _body, {:error, :precondition_failed}}, &1))
      assert {:ok, ^winner, %{etag: ^etag}} = ObjectStore.get(hd(stores), key)
    end
  end
end
