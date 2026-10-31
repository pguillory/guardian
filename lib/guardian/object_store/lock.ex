defmodule Guardian.ObjectStore.Lock do
  @moduledoc """
  A lease lock on one key of a `Guardian.ObjectStore`: the lock is the object itself,
  not an Erlang lock, so it also holds across a network partition. The caller chooses
  the key and the lease; every contender for a key must use the same lease, since the
  object does not record it.

  - Acquire: create the object with `If-None-Match: *`. If it exists, read it: a
    released lock, or one whose lease has run out by the store's own clock (the
    object's age, from its Last-Modified and the store's Date), is taken over with
    `If-Match` on the ETag read. A live lock is not waited for: acquiring makes one
    attempt and returns `{:error, :busy}`, and the caller decides whether and when
    to try again.
  - Release: overwrite with a released body, `If-Match` on the holder's own ETag, so a
    holder whose lease ran out can never release a successor's lock.

  It is a lease, not a fence: a holder that outlasts its lease can overlap the next
  holder.
  """

  @lease_ms 120_000

  defstruct [:store, :key, :etag]

  @doc """
  Makes one attempt to acquire the lock on `key` for `holder` (a description).
  Option: `:lease_ms` (default 120 s). `{:ok, lock}`; `{:error, :busy}` when the lock
  is live, or another contender won a race to create or take it over; or
  `{:error, reason}` from the store.
  """
  def acquire(store, key, holder, opts \\ []) do
    lease_ms = Keyword.get(opts, :lease_ms, @lease_ms)
    body = body(holder, "held")

    case create_or_take_over(store, key, body, lease_ms) do
      {:ok, etag} ->
        {:ok, %__MODULE__{store: store, key: key, etag: etag}}

      {:error, lost} when lost in [:busy, :precondition_failed] ->
        {:error, :busy}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A lock that vanished between the create and the read, or a takeover another
  # contender made first (`:precondition_failed`), means someone else is at it: busy.
  defp create_or_take_over(store, key, body, lease_ms) do
    case Guardian.ObjectStore.put(store, key, body, :absent) do
      {:ok, etag} ->
        {:ok, etag}

      {:error, :precondition_failed} ->
        case Guardian.ObjectStore.get(store, key) do
          {:ok, current, meta} ->
            cond do
              released?(current) or meta.age_ms >= lease_ms ->
                Guardian.ObjectStore.put(store, key, body, {:etag, meta.etag})

              true ->
                {:error, :busy}
            end

          {:error, :not_found} ->
            {:error, :busy}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
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
end
