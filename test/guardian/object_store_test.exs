defmodule Guardian.ObjectStoreTest do
  use ExUnit.Case, async: false
  alias Guardian.ObjectStore

  defmodule ConfigurableStore do
    @moduledoc false

    def shared?(config) do
      config.shared?
    end
  end

  setup do
    s3 = Guardian.FakeS3.start(page_size: 2)
    on_exit(fn -> Guardian.FakeS3.stop(s3) end)
    dir = Path.join(System.tmp_dir!(), "object_store_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, local} = Guardian.ObjectStore.Local.new(dir)
    %{s3: s3, stores: [local: local, s3: Guardian.FakeS3.store(s3, "guardian/")]}
  end

  test "stores declare whether conditional writes coordinate across nodes", %{stores: stores} do
    refute ObjectStore.shared?(stores[:local])
    assert ObjectStore.shared?(stores[:s3])
    refute ObjectStore.shared?({ConfigurableStore, %{shared?: false}})
    assert ObjectStore.shared?({ConfigurableStore, %{shared?: true}})
  end

  test "a store without the optional callback is assumed shared" do
    assert ObjectStore.shared?({__MODULE__, :unused})
  end

  test "list, get, conditional put and delete behave the same on both stores", %{
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
end
