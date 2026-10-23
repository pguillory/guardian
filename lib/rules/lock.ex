defmodule Rules.Lock do
  @moduledoc """
  The cluster-wide rule write lock: an object in the rule store (`_write.lock`), not
  an Erlang lock, so it also holds across a network partition.

  - Acquire: create the object with `If-None-Match: *`. If it exists, read it: a
    released lock, or one whose lease has run out by the store's own clock (the
    object's age, from its Last-Modified and the store's Date), is taken over with
    `If-Match` on the ETag read. A live lock is retried until `@acquire_timeout_ms`.
  - The holder's own deadline is measured from just before its create, so it never
    outlives the lease as the store sees it.
  - Release: overwrite with a released body, `If-Match` on the holder's own ETag, so a
    holder whose lease ran out can never release a successor's lock.

  What it cannot do, with no commit object: fence a holder that stalls past its lease
  after checking it (`remaining_ms/1`), or a write the store applies long after the
  holder gave up on it. `Rules.Server` checks for `@save_margin_ms` left before its
  one write, whose deadline is 20 s, and leaves the lock to expire when a write's
  outcome is unknown.
  """

  @key "_write.lock"
  @lease_ms 120_000
  @save_margin_ms 80_000
  @acquire_timeout_ms 10_000
  @retry_ms 500

  defstruct [:store, :etag, :deadline]

  def key, do: @key

  # Tests shorten the lease (and the margin with it) through app env.
  defp lease_ms, do: Application.get_env(:guardian, :rules_lock_lease_ms, @lease_ms)

  @doc "How much of the lease must be left before the one write a holder makes."
  def save_margin_ms,
    do: Application.get_env(:guardian, :rules_save_margin_ms, @save_margin_ms)

  @doc "Acquires the lock for `holder` (a description). `{:ok, lock}` or `{:error, reason}`."
  def acquire(store, holder, timeout_ms \\ @acquire_timeout_ms) do
    give_up_at = now() + timeout_ms
    attempt(store, body(holder, "held"), give_up_at)
  end

  defp attempt(store, body, give_up_at) do
    started = now()

    result =
      case Rules.Store.put(store, @key, body, :absent) do
        {:ok, etag} ->
          {:ok, etag}

        {:error, :precondition_failed} ->
          case Rules.Store.get(store, @key) do
            {:ok, current, meta} ->
              if released?(current) or meta.age_ms >= lease_ms() do
                Rules.Store.put(store, @key, body, {:etag, meta.etag})
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
        {:ok, %__MODULE__{store: store, etag: etag, deadline: started + lease_ms()}}

      {:error, retryable} when retryable in [:busy, :retry, :precondition_failed] ->
        if now() + @retry_ms < give_up_at do
          Process.sleep(@retry_ms)
          attempt(store, body, give_up_at)
        else
          {:error, :busy}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Milliseconds left on the lease, by this node's monotonic clock."
  def remaining_ms(%__MODULE__{deadline: deadline}), do: deadline - now()

  @doc "Releases the lock if this holder still has it."
  def release(%__MODULE__{store: store, etag: etag}) do
    case Rules.Store.put(store, @key, body("", "released"), {:etag, etag}) do
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

  defp now, do: System.monotonic_time(:millisecond)
end
