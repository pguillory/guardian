defmodule Guardian.ObjectStore.Lock do
  @moduledoc """
  A lease lock on one key of a `Guardian.ObjectStore`: the lock is the object itself,
  not an Erlang lock, so it also holds across a network partition. The caller chooses
  the key and the lease; every contender for a key must use the same lease, since the
  object does not record it.

  - Acquire: create the object with `If-None-Match: *`. If it exists, read it: a
    released lock, or one whose lease has run out by the store's own clock (the
    object's age, from its Last-Modified and the store's Date), is taken over with
    `If-Match` on the ETag read. A live lock is retried every 500 ms until the
    timeout.
  - The holder's own deadline is measured from just before its create, so it never
    outlives the lease as the store sees it.
  - Release: overwrite with a released body, `If-Match` on the holder's own ETag, so a
    holder whose lease ran out can never release a successor's lock.

  It is a lease, not a fence. With no commit object it cannot fence a holder that
  stalls past its lease after checking it (`remaining_ms/1`), or a write the store
  applies long after the holder gave up on it. Callers check enough lease is left
  before each write they make under it (more than that write's deadline), and leave
  the lock to expire, rather than releasing it, when a write's outcome is unknown.
  """

  @lease_ms 120_000
  @acquire_timeout_ms 10_000
  @retry_ms 500

  defstruct [:store, :key, :etag, :deadline]

  @doc """
  Acquires the lock on `key` for `holder` (a description). Options: `:lease_ms`
  (default 120 s) and `:timeout_ms`, how long to retry a live lock (default 10 s).
  `{:ok, lock}`, `{:error, :busy}`, or `{:error, reason}` from the store.
  """
  def acquire(store, key, holder, opts \\ []) do
    lease_ms = Keyword.get(opts, :lease_ms, @lease_ms)
    give_up_at = now() + Keyword.get(opts, :timeout_ms, @acquire_timeout_ms)
    attempt(store, key, body(holder, "held"), lease_ms, give_up_at)
  end

  defp attempt(store, key, body, lease_ms, give_up_at) do
    started = now()

    result =
      case Guardian.ObjectStore.put(store, key, body, :absent) do
        {:ok, etag} ->
          {:ok, etag}

        {:error, :precondition_failed} ->
          case Guardian.ObjectStore.get(store, key) do
            {:ok, current, meta} ->
              if released?(current) or meta.age_ms >= lease_ms do
                Guardian.ObjectStore.put(store, key, body, {:etag, meta.etag})
              else
                {:error, :busy}
              end

            {:error, :not_found} ->
              {:error, :retry}

            {:error, reason} ->
              {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end

    case result do
      {:ok, etag} ->
        {:ok, %__MODULE__{store: store, key: key, etag: etag, deadline: started + lease_ms}}

      {:error, retryable} when retryable in [:busy, :retry, :precondition_failed] ->
        if now() + @retry_ms < give_up_at do
          Process.sleep(@retry_ms)
          attempt(store, key, body, lease_ms, give_up_at)
        else
          {:error, :busy}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Milliseconds left on the lease, by this node's monotonic clock."
  def remaining_ms(%__MODULE__{deadline: deadline}) do
    deadline - now()
  end

  @doc "Releases the lock if this holder still has it."
  def release(%__MODULE__{store: store, key: key, etag: etag}) do
    case Guardian.ObjectStore.put(store, key, body("", "released"), {:etag, etag}) do
      {:ok, _etag} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp body(holder, state) do
    Jason.encode!(%{
      state: state,
      holder: holder,
      token: Base.encode16(:crypto.strong_rand_bytes(8)),
    })
  end

  defp released?(body) do
    match?({:ok, %{"state" => "released"}}, Jason.decode(body))
  end

  defp now do
    System.monotonic_time(:millisecond)
  end
end
