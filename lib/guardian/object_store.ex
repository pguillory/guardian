defmodule Guardian.ObjectStore do
  @moduledoc """
  The generic object-store client: a behaviour for stores of keyed objects with
  conditional writes, and the functions that call one. `Guardian.ObjectStore.S3` is an
  S3-compatible bucket (Cloudflare R2, or any S3 API), `Guardian.ObjectStore.Local` a
  local folder; `Guardian.ObjectStore.Lock` is a lease lock on one key of either. The
  layer knows nothing about its callers' keys.

  A store is `{module, config}`. A failure is `{:error, :not_found}`,
  `{:error, :precondition_failed}` (a conditional request lost), or `{:error, message}`
  for anything else.
  """

  @type t :: {module(), term()}
  @type reason :: :not_found | :precondition_failed | String.t()
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
end
