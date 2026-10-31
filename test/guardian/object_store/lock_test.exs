defmodule Guardian.ObjectStore.LockTest do
  use ExUnit.Case, async: true
  import Guardian.ObjectStore.Lock

  setup do
    dir = Path.join(System.tmp_dir!(), "object_store_lock_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, store} = Guardian.ObjectStore.Local.new(dir)
    %{store: store}
  end

  test "one holder at a time per key; release lets the next in", %{store: store} do
    assert {:ok, lock} = acquire(store, "jobs/a.lock", "a")
    assert acquire(store, "jobs/a.lock", "b") == {:error, :busy}

    # Another key is independent of the first, and is released on its own.
    assert {:ok, other} = acquire(store, "jobs/b.lock", "b")
    assert release(other) == :ok
    assert acquire(store, "jobs/a.lock", "b") == {:error, :busy}

    assert release(lock) == :ok
    assert {:ok, _lock} = acquire(store, "jobs/a.lock", "b")
  end

  test "an expired lease is taken over, and the old holder cannot release its successor",
       %{store: store} do
    assert {:ok, old} = acquire(store, "k", "old")
    # By this contender's lease, the lock has already run out.
    assert {:ok, new} = acquire(store, "k", "new", lease_ms: 0)
    assert release(old) == {:error, :precondition_failed}
    assert acquire(store, "k", "third") == {:error, :busy}
    assert release(new) == :ok
    assert {:ok, _lock} = acquire(store, "k", "third")
  end

  test "concurrent acquisitions have one holder per key, on create and released takeover", %{
    store: store,
  } do
    # Keep every winner held until all contenders finish. The next round races the
    # released objects rather than their initial creation.
    for round <- 1..2 do
      tasks =
        for key <- ~w[k0 k1 k2 k3 k4], n <- 1..4 do
          Task.async(fn ->
            receive do
              :go -> {key, acquire(store, key, "#{key}:#{round}:#{n}")}
            end
          end)
        end

      Enum.each(tasks, &send(&1.pid, :go))
      results = Task.await_many(tasks, 30_000)

      for {key, key_results} <- Enum.group_by(results, &elem(&1, 0)) do
        {wins, losses} = Enum.split_with(key_results, &match?({_key, {:ok, _}}, &1))
        assert [{^key, {:ok, lock}}] = wins
        assert Enum.all?(losses, &(&1 == {key, {:error, :busy}}))
        assert release(lock) == :ok
      end
    end
  end
end
