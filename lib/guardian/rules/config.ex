defmodule Guardian.Rules.Config do
  @moduledoc """
  Chooses the rule store from the environment, at startup.

  - `GUARDIAN_RULES_S3_BUCKET` set: an S3-compatible bucket, which also needs
    `GUARDIAN_RULES_S3_ENDPOINT` (an `https://` URL; `http://` only for a server on
    this machine: the host `localhost`, an IPv4 address in 127.0.0.0/8, or `[::1]`),
    `GUARDIAN_RULES_S3_ACCESS_KEY_ID` and
    `GUARDIAN_RULES_S3_SECRET_ACCESS_KEY`; `GUARDIAN_RULES_S3_REGION` (default `auto`,
    right for R2) and `GUARDIAN_RULES_S3_PREFIX` (default none; a non-empty prefix
    must end in `/`) are optional.
  - Otherwise a local folder: `GUARDIAN_RULES_DIR`, default `<data dir>/rules`.

  Setting the folder and the bucket, or only some of the bucket settings, is an
  error. The secrets are read here and kept only inside a closure
  (`Guardian.ObjectStore.S3`), never in application config.

  Tests set `:guardian, :rules_store` to a store directly, skipping the environment.
  """

  alias Guardian.ObjectStore

  @max_list_pages 20

  @s3_vars ~w[
    GUARDIAN_RULES_S3_BUCKET
    GUARDIAN_RULES_S3_ENDPOINT
    GUARDIAN_RULES_S3_ACCESS_KEY_ID
    GUARDIAN_RULES_S3_SECRET_ACCESS_KEY
  ]

  @doc "The configured store: `{:ok, store}` or `{:error, message}`."
  def store(env \\ System.get_env()) do
    case Application.get_env(:guardian, :rules_store) do
      nil -> from_env(env)
      store -> {:ok, store}
    end
  end

  @doc false
  def from_env(env) do
    s3 = Map.new(@s3_vars, &{&1, blank_to_nil(env[&1])})
    dir = blank_to_nil(env["GUARDIAN_RULES_DIR"])

    optional =
      Enum.filter(~w[GUARDIAN_RULES_S3_REGION GUARDIAN_RULES_S3_PREFIX], &blank_to_nil(env[&1]))

    cond do
      Enum.all?(Map.values(s3), &is_nil/1) and optional != [] ->
        {:error, "#{Enum.join(optional, " and ")} set without GUARDIAN_RULES_S3_BUCKET"}

      Enum.all?(Map.values(s3), &is_nil/1) ->
        dir = dir || Path.join(Application.fetch_env!(:guardian, :data_dir), "rules")

        case Guardian.Rules.Store.Local.new(dir) do
          {:ok, store} -> {:ok, store}
          {:error, reason} -> {:error, Guardian.ObjectStore.reason_message(reason)}
        end

      dir != nil ->
        {:error, "set either GUARDIAN_RULES_DIR or the GUARDIAN_RULES_S3_* settings, not both"}

      (missing = Enum.filter(@s3_vars, &is_nil(s3[&1]))) != [] ->
        {:error, "rule store settings missing: #{Enum.join(missing, ", ")}"}

      true ->
        s3_store(s3, env)
    end
  end

  defp s3_store(s3, env) do
    endpoint = String.trim_trailing(s3["GUARDIAN_RULES_S3_ENDPOINT"], "/")
    prefix = env["GUARDIAN_RULES_S3_PREFIX"] || ""

    cond do
      (error = ObjectStore.S3.check_endpoint(endpoint)) != :ok ->
        {:error, endpoint_message(error)}

      (error = ObjectStore.S3.check_prefix(prefix)) != :ok ->
        {:error, prefix_message(error)}

      true ->
        access_key_id = s3["GUARDIAN_RULES_S3_ACCESS_KEY_ID"]
        secret_access_key = s3["GUARDIAN_RULES_S3_SECRET_ACCESS_KEY"]

        config = %ObjectStore.S3{
          endpoint: endpoint,
          bucket: s3["GUARDIAN_RULES_S3_BUCKET"],
          region: blank_to_nil(env["GUARDIAN_RULES_S3_REGION"]) || "auto",
          prefix: prefix,
          credentials: fn -> {access_key_id, secret_access_key} end,
          # Rule sets hold at most 1,000 files (`Guardian.Rules.RuleSet`); a store
          # that keeps paging past this many is refused rather than followed forever.
          max_list_pages: @max_list_pages,
        }

        {:ok, {ObjectStore.S3, config}}
    end
  end

  defp endpoint_message({:error, :not_url}) do
    "GUARDIAN_RULES_S3_ENDPOINT must be a URL like https://<host>, with no path"
  end

  defp endpoint_message({:error, :insecure}) do
    "GUARDIAN_RULES_S3_ENDPOINT must use https:// (http:// only for localhost, " <>
      "127.0.0.0/8 or [::1])"
  end

  defp prefix_message({:error, :no_trailing_slash}) do
    "GUARDIAN_RULES_S3_PREFIX must end in /"
  end

  defp prefix_message({:error, :invalid_characters}) do
    "GUARDIAN_RULES_S3_PREFIX may use only letters, digits, and . _ ~ / -"
  end

  defp blank_to_nil(nil) do
    nil
  end

  defp blank_to_nil("") do
    nil
  end

  defp blank_to_nil(value) do
    value
  end
end
