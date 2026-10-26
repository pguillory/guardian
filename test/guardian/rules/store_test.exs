defmodule Guardian.Rules.StoreTest do
  use ExUnit.Case, async: false
  alias Guardian.ObjectStore
  alias Guardian.Rules.Store

  setup do
    s3 = Guardian.FakeS3.start(page_size: 2)
    on_exit(fn -> Guardian.FakeS3.stop(s3) end)
    dir = Path.join(System.tmp_dir!(), "rules_store_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, local} = Guardian.Rules.Store.Local.new(dir)
    %{s3: s3, stores: [local: local, s3: Guardian.FakeS3.store(s3, "guardian/")]}
  end

  test "list, get, conditional put and delete behave the same on both rule stores", %{
    stores: stores,
  } do
    for {_kind, store} <- stores do
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
  end

  test "the local store skips folders named like rule files and fails on unreadable ones", %{
    stores: stores,
  } do
    {Store.Local, %{dir: dir}} = local = stores[:local]
    File.mkdir_p!(Path.join(dir, "t/folder.gsql"))
    # A temporary file left by a crash mid-write is not a rule file.
    File.write!(Path.join(dir, "t/a.gsql.123.tmp"), "SET y = 1")
    {:ok, _} = ObjectStore.put(local, "t/a.gsql", "SET x = 1", :absent)
    assert {:ok, [%{key: "t/a.gsql"}]} = ObjectStore.list(local)

    path = Path.join(dir, "t/a.gsql")
    File.chmod!(path, 0o000)
    on_exit(fn -> File.chmod(path, 0o644) end)
    assert {:error, {:failed, "t/a.gsql: eacces"}} = ObjectStore.list(local)
  end

  test "local writes replace the file and leave no temp file, even when they fail", %{
    stores: stores,
  } do
    {Store.Local, %{dir: dir}} = local = stores[:local]
    {:ok, etag1} = ObjectStore.put(local, "t/a.gsql", "SET a = 1", :absent)
    {:ok, _} = ObjectStore.put(local, "t/a.gsql", "SET a = 2", {:etag, etag1})
    assert File.read!(Path.join(dir, "t/a.gsql")) == "SET a = 2"
    assert File.ls!(Path.join(dir, "t")) == ["a.gsql"]

    # Renaming over a nonempty folder fails after the temp file is written.
    File.mkdir_p!(Path.join(dir, "u/b.gsql/child"))
    assert {:error, {:failed, _posix}} = ObjectStore.put(local, "u/b.gsql", "SET b = 1", :none)
    assert File.ls!(Path.join(dir, "u")) == ["b.gsql"]
  end
end
