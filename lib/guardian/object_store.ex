defmodule Guardian.ObjectStore do
  @moduledoc """
  The generic object-store client: a behaviour for stores of keyed objects with
  conditional writes, and the functions that call one. `Guardian.ObjectStore.S3` is the
  S3-compatible implementation (Cloudflare R2, or any S3 API);
  `Guardian.ObjectStore.Lock` is a lease lock on one key of any store. The layer knows
  nothing about its callers' keys; a caller may supply its own implementation of the
  behaviour.

  A store is `{module, config}`. Results never carry credentials or response bodies:
  failures are `{:error, reason}` with reason one of

  - `:not_found`, `:precondition_failed` (a conditional request lost)
  - `{:unreachable, kind}`: could not get an answer, and safe to retry (connection,
    timeout, a 5xx on a read, or a read rate limited with 429)
  - `{:misconfigured, kind}`: the store answered that the settings are wrong (bad
    credentials, missing bucket or folder)
  - `{:unknown, kind}`: a write whose outcome is unknown (its deadline passed or the
    connection dropped after sending)
  - `{:failed, kind}`: the request failed in a known way and did not change the store
    (a write rate limited with 429, another unexpected status, a local file error)
  """

  @type t :: {module(), term()}
  @type reason ::
          :not_found
          | :precondition_failed
          | {:unreachable | :misconfigured | :unknown | :failed, String.t()}
  @type object :: %{key: String.t(), etag: String.t(), size: non_neg_integer()}
  @type meta :: %{etag: String.t(), age_ms: integer()}
  @type condition :: :none | :absent | {:etag, String.t()}

  @callback list(term()) :: {:ok, [object()]} | {:error, reason()}
  @callback get(term(), String.t(), String.t() | nil) ::
              {:ok, binary(), meta()} | {:error, reason()}
  @callback put(term(), String.t(), binary(), condition()) ::
              {:ok, String.t()} | {:error, reason()}
  @callback delete(term(), String.t()) :: :ok | {:error, reason()}
  @callback describe(term()) :: String.t()

  def list({mod, config}) do
    mod.list(config)
  end

  @doc """
  Gets `key`. With `etag`, only that version: a different one is
  `{:error, :precondition_failed}`. `meta.age_ms` is how long ago the object was last
  modified, by the store's own clock.
  """
  def get({mod, config}, key, etag \\ nil) do
    mod.get(config, key, etag)
  end

  @doc """
  Puts `key`: unconditionally (`:none`), only if it does not exist (`:absent`), or
  only if its current ETag is `etag`. Returns the new ETag.
  """
  def put({mod, config}, key, body, condition) do
    mod.put(config, key, body, condition)
  end

  def delete({mod, config}, key) do
    mod.delete(config, key)
  end

  @doc "A description of the store for logs: its kind and location, never a secret."
  def describe({mod, config}) do
    mod.describe(config)
  end

  @doc "A message for a failure reason, safe to log and to return to clients."
  def reason_message(:not_found) do
    "not found"
  end

  def reason_message(:precondition_failed) do
    "changed concurrently"
  end

  def reason_message({:unreachable, kind}) do
    "store unreachable (#{kind})"
  end

  def reason_message({:misconfigured, kind}) do
    "store misconfigured (#{kind})"
  end

  def reason_message({:unknown, kind}) do
    "outcome unknown (#{kind})"
  end

  def reason_message({:failed, kind}) do
    "store request failed (#{kind})"
  end
end
