defmodule Guardian.ObjectStore.LockTest do
  use ExUnit.Case, async: false

  alias Guardian.ObjectStore.Lock

  setup do
    s3 = Guardian.FakeS3.start()
    on_exit(fn -> Guardian.FakeS3.stop(s3) end)
    %{s3: s3, store: Guardian.FakeS3.store(s3)}
  end

  defp lock_state(store, key) do
    {:ok, body, _meta} = Guardian.ObjectStore.get(store, key)
    Jason.decode!(body)["state"]
  end

  test "one holder at a time per key; release lets the next in", %{store: store} do
    assert {:ok, lock} = Lock.acquire(store, "jobs/a.lock", "a")
    assert Lock.remaining_ms(lock) > 100_000
    assert Lock.acquire(store, "jobs/a.lock", "b", timeout_ms: 600) == {:error, :busy}

    # Another key is independent of the first, and is released on its own.
    assert {:ok, other} = Lock.acquire(store, "jobs/b.lock", "b", timeout_ms: 600)
    assert Lock.release(other) == :ok
    assert lock_state(store, "jobs/b.lock") == "released"
    assert lock_state(store, "jobs/a.lock") == "held"

    assert Lock.release(lock) == :ok
    assert lock_state(store, "jobs/a.lock") == "released"
    assert {:ok, _lock} = Lock.acquire(store, "jobs/a.lock", "b", timeout_ms: 600)
  end

  test "an expired lease is taken over, and the old holder cannot release its successor",
       %{s3: s3, store: store} do
    assert {:ok, old} = Lock.acquire(store, "k", "old", lease_ms: 30_000)
    assert Lock.remaining_ms(old) <= 30_000 and Lock.remaining_ms(old) > 25_000
    Guardian.FakeS3.age(s3, "k", 31)
    assert {:ok, new} = Lock.acquire(store, "k", "new", lease_ms: 30_000, timeout_ms: 600)
    assert Lock.release(old) == {:error, :precondition_failed}
    assert lock_state(store, "k") == "held"
    assert Lock.acquire(store, "k", "third", lease_ms: 30_000, timeout_ms: 600) == {:error, :busy}
    assert Lock.release(new) == :ok
  end

  test "the lease is judged by the store's clock, not the holder's", %{s3: s3, store: store} do
    assert {:ok, _lock} = Lock.acquire(store, "k", "a")
    # Not aged past the default lease on the store: still live, however long this
    # node thinks it has waited.
    Guardian.FakeS3.age(s3, "k", 60)
    assert Lock.acquire(store, "k", "b", timeout_ms: 600) == {:error, :busy}
  end

  test "works on a local folder too" do
    dir = Path.join(System.tmp_dir!(), "object_store_lock_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, store} = Guardian.ObjectStore.Local.new(dir)
    key = "k"
    assert {:ok, lock} = Lock.acquire(store, key, "a")
    assert Lock.acquire(store, key, "b", timeout_ms: 600) == {:error, :busy}
    assert Lock.release(lock) == :ok
    assert {:ok, _lock} = Lock.acquire(store, key, "b", timeout_ms: 600)
  end
end
