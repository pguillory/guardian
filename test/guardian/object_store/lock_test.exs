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
    lock_body(store, key)["state"]
  end

  defp lock_holder(store, key) do
    lock_body(store, key)["holder"]
  end

  defp lock_body(store, key) do
    {:ok, body, _meta} = ObjectStore.get(store, key)
    Jason.decode!(body)
  end

  defp local_store! do
    dir = Path.join(System.tmp_dir!(), "object_store_lock_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, store} = ObjectStore.Local.new(dir)
    store
  end

  test "one holder at a time per key; release lets the next in", %{store: store} do
    assert {:ok, lock} = acquire(store, "jobs/a.lock", "a")
    assert acquire(store, "jobs/a.lock", "b") == {:error, :busy}

    # Another key is independent of the first, and is released on its own.
    assert {:ok, other} = acquire(store, "jobs/b.lock", "b")
    assert release(other) == :ok
    assert lock_state(store, "jobs/b.lock") == "released"
    assert lock_state(store, "jobs/a.lock") == "held"

    assert release(lock) == :ok
    assert lock_state(store, "jobs/a.lock") == "released"
    assert {:ok, _lock} = acquire(store, "jobs/a.lock", "b")
  end

  test "an expired lease is taken over, and the old holder cannot release its successor",
       %{s3: s3, store: store} do
    assert {:ok, old} = acquire(store, "k", "old", lease_ms: 30_000)
    assert remaining_ms(old) <= 30_000
    Guardian.Test.FakeS3.age(s3, "k", 31)
    assert {:ok, new} = acquire(store, "k", "new", lease_ms: 30_000)
    assert lock_holder(store, "k") == "new"
    assert release(old) == {:error, :precondition_failed}
    assert lock_state(store, "k") == "held"
    assert acquire(store, "k", "third", lease_ms: 30_000) == {:error, :busy}
    assert release(new) == :ok
  end

  test "the lease is judged by the store's clock, not the holder's", %{s3: s3, store: store} do
    assert {:ok, _lock} = acquire(store, "k", "a")
    # Not aged past the default lease on the store: still live.
    Guardian.Test.FakeS3.age(s3, "k", 60)
    assert acquire(store, "k", "b") == {:error, :busy}
  end

  defp lock_requests(s3, key) do
    s3
    |> Guardian.Test.FakeS3.requests()
    |> Enum.filter(&String.ends_with?(&1.path, "/" <> key))
    |> Enum.map(& &1.method)
  end

  test "a live lock is busy after one create and one read, without waiting", %{
    s3: s3,
    store: store,
  } do
    assert {:ok, _lock} = acquire(store, "k", "a")
    assert acquire(store, "k", "b") == {:error, :busy}
    assert lock_requests(s3, "k") == ["PUT", "PUT", "GET"]
  end

  test "a lock gone between the create and the read is busy", %{s3: s3, store: store} do
    assert {:ok, _lock} = acquire(store, "k", "a")
    # The create fails on the live lock; the read then finds nothing.
    Guardian.Test.FakeS3.fault(s3, [nil, {:status, 404}])
    assert acquire(store, "k", "b") == {:error, :busy}
    assert lock_requests(s3, "k") == ["PUT", "PUT", "GET"]
  end

  test "a takeover another contender made first is busy", %{s3: s3, store: store} do
    assert {:ok, lock} = acquire(store, "k", "a")
    assert release(lock) == :ok
    # The create fails on the released lock, the read succeeds, the takeover loses.
    Guardian.Test.FakeS3.fault(s3, [nil, nil, {:status, 412}])
    assert acquire(store, "k", "b") == {:error, :busy}
    assert lock_requests(s3, "k") == ["PUT", "PUT", "PUT", "GET", "PUT"]
  end

  # A store whose one object exists with the given state and no known age, as from an
  # S3-compatible store whose responses carry no Last-Modified Guardian can parse.
  defmodule AgelessStore do
    @behaviour Guardian.ObjectStore

    @impl true
    def get(state, _key, _etag) do
      {:ok, Jason.encode!(%{state: state, holder: "a"}), %{etag: "e1", age_ms: nil}}
    end

    @impl true
    def put(_state, _key, _body, :absent) do
      {:error, :precondition_failed}
    end

    def put(_state, _key, _body, {:etag, "e1"}) do
      {:ok, "e2"}
    end

    @impl true
    def list(_state) do
      {:ok, []}
    end

    @impl true
    def delete(_state, _key) do
      :ok
    end

    @impl true
    def describe(_state) do
      "ageless"
    end
  end

  test "a held lock of unknown age is an error, not busy forever; a released one is taken over" do
    assert acquire({AgelessStore, "held"}, "k", "b") == {:error, {:failed, "lock age unknown"}}
    assert {:ok, _lock} = acquire({AgelessStore, "released"}, "k", "b")
  end

  test "works on a local folder too" do
    store = local_store!()
    key = "k"
    assert {:ok, lock} = acquire(store, key, "a")
    assert acquire(store, key, "b") == {:error, :busy}
    assert release(lock) == :ok
    assert {:ok, _lock} = acquire(store, key, "b")
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
                {key, holder, acquire(store, key, holder)}
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
