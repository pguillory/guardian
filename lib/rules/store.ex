defmodule Guardian.Rules.Store do
  @moduledoc """
  Where rule files live: a local folder (`Guardian.Rules.Store.Local`) or an S3-compatible
  bucket (`Guardian.Rules.Store.S3`). There is no index or manifest: listing the store is the
  index, each object one rule file (`<table>/<name>.gsql`), plus the write lock
  (`Guardian.Rules.Lock`), which the loader ignores.

  A store is `{module, config}`. Results never carry credentials or response bodies:
  failures are `{:error, reason}` with reason one of

  - `:not_found`, `:precondition_failed` (a conditional request lost)
  - `{:unreachable, kind}`: could not get an answer, and safe to retry (connection,
    timeout, a 5xx on a read, or a read rate limited with 429); boot retries it
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

  def list({mod, config}), do: mod.list(config)

  @doc """
  Gets `key`. With `etag`, only that version: a different one is
  `{:error, :precondition_failed}`. `meta.age_ms` is how long ago the object was last
  modified, by the store's own clock.
  """
  def get({mod, config}, key, etag \\ nil), do: mod.get(config, key, etag)

  @doc """
  Puts `key`: unconditionally (`:none`), only if it does not exist (`:absent`), or
  only if its current ETag is `etag`. Returns the new ETag.
  """
  def put({mod, config}, key, body, condition), do: mod.put(config, key, body, condition)

  def delete({mod, config}, key), do: mod.delete(config, key)

  @doc "A description of the store for logs: its kind and location, never a secret."
  def describe({mod, config}), do: mod.describe(config)

  def local?({Guardian.Rules.Store.Local, _config}), do: true
  def local?(_store), do: false

  @doc "A message for a failure reason, safe to log and to return to clients."
  def reason_message(:not_found), do: "not found"
  def reason_message(:precondition_failed), do: "changed concurrently"
  def reason_message({:unreachable, kind}), do: "store unreachable (#{kind})"
  def reason_message({:misconfigured, kind}), do: "store misconfigured (#{kind})"
  def reason_message({:unknown, kind}), do: "outcome unknown (#{kind})"
  def reason_message({:failed, kind}), do: "store request failed (#{kind})"
end
