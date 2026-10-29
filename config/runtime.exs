import Config

if config_env() != :test do
  # Resident counter entries/indexes, in MiB; Store defaults to 64 MiB.
  case System.get_env("GUARDIAN_COUNTER_MEMORY_MB") do
    nil ->
      :ok

    value ->
      case Integer.parse(value) do
        {mb, ""} when mb > 0 -> config :guardian, counter_memory_budget_bytes: mb * 1_024 * 1_024
        _ -> raise "GUARDIAN_COUNTER_MEMORY_MB must be a positive integer"
      end
  end

  case System.get_env("GUARDIAN_MUTABLE_SEGMENT_MAX_AGE_MS") do
    nil ->
      :ok

    value ->
      case Integer.parse(value) do
        {max_age_ms, ""} when max_age_ms > 0 ->
          config :guardian, mutable_segment_max_age_ms: max_age_ms

        _ ->
          raise "GUARDIAN_MUTABLE_SEGMENT_MAX_AGE_MS must be a positive integer"
      end
  end

  # API keys: GUARDIAN_INGEST_API_KEY may only send events; GUARDIAN_ADMIN_API_KEY,
  # required, grants everything. Values are never printed.
  api_keys =
    for name <- ~w(GUARDIAN_INGEST_API_KEY GUARDIAN_ADMIN_API_KEY) do
      case System.get_env(name) do
        nil ->
          {name, nil}

        "" ->
          raise "#{name} must not be empty"

        # A length policy, not an entropy check: generate the key (openssl rand -hex 32).
        key when byte_size(key) < 32 ->
          raise "#{name} must be at least 32 bytes; generate one with: openssl rand -hex 32"

        key ->
          {name, key}
      end
    end

  %{"GUARDIAN_INGEST_API_KEY" => ingest_api_key, "GUARDIAN_ADMIN_API_KEY" => admin_api_key} =
    Map.new(api_keys)

  # GUARDIAN_API_KEY, the single full-access key from before the split, is no longer
  # read. A deployment that still sets it in place of the admin key gets an error
  # naming the replacements; alongside the admin key it is ignored.
  if admin_api_key == nil do
    if System.get_env("GUARDIAN_API_KEY") != nil do
      raise "GUARDIAN_API_KEY is no longer supported; set GUARDIAN_ADMIN_API_KEY " <>
              "(full access) and, for clients that only send events, " <>
              "GUARDIAN_INGEST_API_KEY; generate each with: openssl rand -hex 32"
    else
      raise "GUARDIAN_ADMIN_API_KEY must be set; generate one with: openssl rand -hex 32"
    end
  end

  # A shared value would give the ingest key full access, and make keys indistinguishable.
  if ingest_api_key == admin_api_key do
    raise "GUARDIAN_INGEST_API_KEY and GUARDIAN_ADMIN_API_KEY must differ"
  end

  config :guardian, ingest_api_key: ingest_api_key, admin_api_key: admin_api_key

  case System.get_env("GUARDIAN_PORT") do
    value when value in [nil, ""] ->
      :ok

    value ->
      case Integer.parse(value) do
        {port, ""} when port in 1..65_535 -> config :guardian, http_port: port
        _ -> raise "GUARDIAN_PORT must be a port number from 1 to 65535"
      end
  end

  # A DNS name resolving to every peer's address; rel/env.sh.eex defaults it on Fly.io.
  # Unset means no peer discovery. Guardian.Cluster.discovery_child_spec/1 checks the node name.
  case System.get_env("DNS_CLUSTER_QUERY") do
    query when query in [nil, ""] -> :ok
    query -> config :guardian, dns_cluster_query: query
  end
end

if config_env() == :prod do
  data_dir = System.get_env("GUARDIAN_DATA_DIR", "/root/data")
  if data_dir == "", do: raise("GUARDIAN_DATA_DIR must not be empty")

  # On Fly.io the data directory must be the machine's volume. Without the mount it would
  # be the image's disposable root filesystem, and events would vanish on restart.
  if System.get_env("FLY_PRIVATE_IP", "") != "" do
    parent = Path.dirname(Path.expand(data_dir))

    mounted? =
      with {:ok, %File.Stat{major_device: dir_device}} <- File.stat(data_dir),
           {:ok, %File.Stat{major_device: parent_device}} <- File.stat(parent) do
        dir_device != parent_device
      else
        _ -> false
      end

    unless mounted? do
      raise "GUARDIAN_DATA_DIR #{inspect(data_dir)} is not a mounted volume; " <>
              "on Fly it must be the volume's mount point ([mounts] in fly.toml)"
    end
  end

  # Fail at boot, not at the first segment write, if the directory is read-only.
  probe = Path.join(data_dir, ".write_probe")

  with :ok <- File.mkdir_p(Path.join(data_dir, "segments")),
       :ok <- File.write(probe, ""),
       :ok <- File.rm(probe) do
    config :guardian, data_dir: data_dir
  else
    {:error, reason} ->
      raise "GUARDIAN_DATA_DIR #{inspect(data_dir)} is not writable: #{:file.format_error(reason)}"
  end
end
