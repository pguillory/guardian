defmodule Rules.LockTest do
  use ExUnit.Case, async: false
  import RulesTestHelper

  alias Rules.Lock

  setup do
    s3 = FakeS3.start()
    on_exit(fn -> FakeS3.stop(s3) end)
    %{s3: s3, store: FakeS3.store(s3)}
  end

  defp lock_state(store) do
    {:ok, body, _meta} = Rules.Store.get(store, Lock.key())
    Jason.decode!(body)["state"]
  end

  test "one holder at a time; release lets the next in", %{store: store} do
    assert {:ok, lock} = Lock.acquire(store, "a")
    assert Lock.remaining_ms(lock) > 100_000
    assert Lock.acquire(store, "b", 600) == {:error, :busy}
    assert Lock.release(lock) == :ok
    assert lock_state(store) == "released"
    assert {:ok, _lock} = Lock.acquire(store, "b", 600)
  end

  test "an expired lease is taken over, and the old holder cannot release its successor",
       %{s3: s3, store: store} do
    assert {:ok, old} = Lock.acquire(store, "old")
    FakeS3.age(s3, Lock.key(), 121)
    assert {:ok, new} = Lock.acquire(store, "new", 600)
    assert Lock.release(old) == {:error, :precondition_failed}
    assert lock_state(store) == "held"
    assert Lock.acquire(store, "third", 600) == {:error, :busy}
    assert Lock.release(new) == :ok
  end

  test "the lease is judged by the store's clock, not the holder's", %{s3: s3, store: store} do
    put_env(:rules_lock_lease_ms, 120_000)
    assert {:ok, _lock} = Lock.acquire(store, "a")
    # Not aged on the store: still live, however long this node thinks it has waited.
    FakeS3.age(s3, Lock.key(), 60)
    assert Lock.acquire(store, "b", 600) == {:error, :busy}
  end

  test "works on a local folder too" do
    dir = Path.join(System.tmp_dir!(), "rules_lock_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, store} = Rules.Store.Local.new(dir)
    assert {:ok, lock} = Lock.acquire(store, "a")
    assert Lock.acquire(store, "b", 600) == {:error, :busy}
    assert Lock.release(lock) == :ok
    assert {:ok, _lock} = Lock.acquire(store, "b", 600)
  end
end
