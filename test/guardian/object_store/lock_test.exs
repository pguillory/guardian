defmodule Guardian.ObjectStore.LockTest do
  use ExUnit.Case, async: true
  import Guardian.ObjectStore.Lock

  alias Guardian.ObjectStore

  setup do
    s3 = Guardian.Test.FakeS3.start()
    on_exit(fn -> Guardian.Test.FakeS3.stop(s3) end)
    %{s3: s3, store: Guardian.Test.FakeS3.store(s3)}
  end

  defp lock_state(store, key) do
    {:ok, body, _meta} = ObjectStore.get(store, key)
    Jason.decode!(body)["state"]
  end

  defp local_store! do
    dir = Path.join(System.tmp_dir!(), "object_store_lock_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, store} = ObjectStore.Local.new(dir)
    store
  end

  test "one holder at a time per key; release lets the next in", %{store: store} do
    assert {:ok, lock} = acquire(store, "jobs/a.lock", "a")
    assert remaining_ms(lock) > 100_000
    assert acquire(store, "jobs/a.lock", "b", timeout_ms: 600) == {:error, :busy}

    # Another key is independent of the first, and is released on its own.
    assert {:ok, other} = acquire(store, "jobs/b.lock", "b", timeout_ms: 600)
    assert release(other) == :ok
    assert lock_state(store, "jobs/b.lock") == "released"
    assert lock_state(store, "jobs/a.lock") == "held"

    assert release(lock) == :ok
    assert lock_state(store, "jobs/a.lock") == "released"
    assert {:ok, _lock} = acquire(store, "jobs/a.lock", "b", timeout_ms: 600)
  end

  test "an expired lease is taken over, and the old holder cannot release its successor",
       %{s3: s3, store: store} do
    assert {:ok, old} = acquire(store, "k", "old", lease_ms: 30_000)
    assert remaining_ms(old) <= 30_000 and remaining_ms(old) > 25_000
    Guardian.Test.FakeS3.age(s3, "k", 31)
    assert {:ok, new} = acquire(store, "k", "new", lease_ms: 30_000, timeout_ms: 600)
    assert release(old) == {:error, :precondition_failed}
    assert lock_state(store, "k") == "held"
    assert acquire(store, "k", "third", lease_ms: 30_000, timeout_ms: 600) == {:error, :busy}
    assert release(new) == :ok
  end

  test "the lease is judged by the store's clock, not the holder's", %{s3: s3, store: store} do
    assert {:ok, _lock} = acquire(store, "k", "a")
    # Not aged past the default lease on the store: still live, however long this
    # node thinks it has waited.
    Guardian.Test.FakeS3.age(s3, "k", 60)
    assert acquire(store, "k", "b", timeout_ms: 600) == {:error, :busy}
  end

  test "works on a local folder too" do
    store = local_store!()
    key = "k"
    assert {:ok, lock} = acquire(store, key, "a")
    assert acquire(store, key, "b", timeout_ms: 600) == {:error, :busy}
    assert release(lock) == :ok
    assert {:ok, _lock} = acquire(store, key, "b", timeout_ms: 600)
  end

  test "concurrent local acquisitions have one holder per key, on create and released takeover" do
    store = local_store!()

    # Keep every winner held until all contenders finish. The next round races the
    # released objects' ETags rather than their initial absent creation.
    for round <- 1..2 do
      tasks =
        for key <- ~w[k0 k1 k2 k3 k4], n <- 1..4 do
          Task.async(fn ->
            receive do
              :go ->
                holder = "#{key}:#{round}:#{n}"
                {key, holder, acquire(store, key, holder, timeout_ms: 0)}
            end
          end)
        end

      Enum.each(tasks, &send(&1.pid, :go))
      results = Task.await_many(tasks, 30_000)

      for {key, key_results} <- Enum.group_by(results, &elem(&1, 0)) do
        {wins, losses} = Enum.split_with(key_results, &match?({_key, _holder, {:ok, _}}, &1))
        assert [{^key, holder, {:ok, lock}}] = wins
        assert Enum.all?(losses, &match?({^key, _holder, {:error, :busy}}, &1))
        assert {:ok, body, %{etag: etag}} = ObjectStore.get(store, key)
        assert etag == lock.etag
        assert %{"state" => "held", "holder" => ^holder} = Jason.decode!(body)
        assert release(lock) == :ok
        assert lock_state(store, key) == "released"
      end
    end
  end
end
