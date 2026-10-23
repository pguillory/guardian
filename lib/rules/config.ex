defmodule Rules.Config do
  @moduledoc """
  Chooses the rule store from the environment, at startup.

  - `GUARDIAN_RULES_S3_BUCKET` set: an S3-compatible bucket, which also needs
    `GUARDIAN_RULES_S3_ENDPOINT` (an `https://` URL, or `http://` for a local test
    server), `GUARDIAN_RULES_S3_ACCESS_KEY_ID` and
    `GUARDIAN_RULES_S3_SECRET_ACCESS_KEY`; `GUARDIAN_RULES_S3_REGION` (default `auto`,
    right for R2) and `GUARDIAN_RULES_S3_PREFIX` (default none; a non-empty prefix
    must end in `/`) are optional.
  - Otherwise a local folder: `GUARDIAN_RULES_DIR`, default `<data dir>/rules`.

  Setting the folder and the bucket, or only some of the bucket settings, is an
  error. The secrets are read here and kept only inside a closure
  (`Rules.Store.S3`), never in application config.

  Tests set `:guardian, :rules_store` to a store directly, skipping the environment.
  """

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

        case Rules.Store.Local.new(dir) do
          {:ok, store} -> {:ok, store}
          {:error, reason} -> {:error, Rules.Store.reason_message(reason)}
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
    uri = URI.parse(endpoint)

    cond do
      uri.scheme not in ["https", "http"] or uri.host in [nil, ""] or uri.path not in [nil, ""] ->
        {:error, "GUARDIAN_RULES_S3_ENDPOINT must be a URL like https://<host>, with no path"}

      prefix != "" and not String.ends_with?(prefix, "/") ->
        {:error, "GUARDIAN_RULES_S3_PREFIX must end in /"}

      not String.match?(prefix, ~r{\A[A-Za-z0-9._~/-]*\z}) ->
        {:error, "GUARDIAN_RULES_S3_PREFIX may use only letters, digits, and . _ ~ / -"}

      true ->
        access_key_id = s3["GUARDIAN_RULES_S3_ACCESS_KEY_ID"]
        secret_access_key = s3["GUARDIAN_RULES_S3_SECRET_ACCESS_KEY"]

        config = %Rules.Store.S3{
          endpoint: endpoint,
          bucket: s3["GUARDIAN_RULES_S3_BUCKET"],
          region: blank_to_nil(env["GUARDIAN_RULES_S3_REGION"]) || "auto",
          prefix: prefix,
          credentials: fn -> {access_key_id, secret_access_key} end,
        }

        {:ok, {Rules.Store.S3, config}}
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
