defmodule Guardian.Config.RuntimeTest do
  use ExUnit.Case, async: false

  @runtime_config Path.expand("../../../config/runtime.exs", __DIR__)
  @environment_variables [
    "GUARDIAN_API_KEY",
    "GUARDIAN_INGEST_API_KEY",
    "GUARDIAN_ADMIN_API_KEY",
    "GUARDIAN_USER_ID",
    "GUARDIAN_DATA_DIR",
    "GUARDIAN_MUTABLE_SEGMENT_MAX_AGE_MS",
    "DNS_CLUSTER_QUERY",
    "FLY_PRIVATE_IP",
    "GUARDIAN_ALLOW_QUERY_API_KEY",
    "GUARDIAN_QUERY_MAX_HEAP_MB",
    "GUARDIAN_PORT",
    "GUARDIAN_COUNTER_MEMORY_MB",
  ]

  # A key long enough for the 32-byte minimum.
  @key String.duplicate("k", 32)

  setup do
    previous_environment =
      Map.new(@environment_variables, fn name -> {name, System.get_env(name)} end)

    on_exit(fn ->
      Enum.each(previous_environment, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    directory =
      Path.join(System.tmp_dir!(), "guardian_runtime_test_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(directory) end)

    System.delete_env("GUARDIAN_USER_ID")
    System.delete_env("GUARDIAN_INGEST_API_KEY")
    System.delete_env("GUARDIAN_ADMIN_API_KEY")
    System.delete_env("DNS_CLUSTER_QUERY")
    System.delete_env("FLY_PRIVATE_IP")
    System.delete_env("GUARDIAN_MUTABLE_SEGMENT_MAX_AGE_MS")
    System.delete_env("GUARDIAN_ALLOW_QUERY_API_KEY")
    System.delete_env("GUARDIAN_QUERY_MAX_HEAP_MB")
    System.delete_env("GUARDIAN_PORT")
    System.delete_env("GUARDIAN_COUNTER_MEMORY_MB")
    System.put_env("GUARDIAN_DATA_DIR", directory)
    %{directory: directory}
  end

  test "loads production authentication configuration from the API key alone" do
    System.put_env("GUARDIAN_API_KEY", @key)

    config = read_runtime_config()

    assert get_in(config, [:guardian, :api_key]) == @key
    refute Keyword.has_key?(config[:guardian], :user_id)
  end

  test "ignores a leftover GUARDIAN_USER_ID" do
    System.put_env("GUARDIAN_API_KEY", @key)
    System.put_env("GUARDIAN_USER_ID", "../not-even-a-uuid")

    config = read_runtime_config()

    assert get_in(config, [:guardian, :api_key]) == @key
    refute Keyword.has_key?(config[:guardian], :user_id)
  end

  test "rejects a configuration without a full-access key" do
    System.delete_env("GUARDIAN_API_KEY")

    message =
      "GUARDIAN_ADMIN_API_KEY must be set (or the deprecated GUARDIAN_API_KEY); " <>
        "generate one with: openssl rand -hex 32"

    assert_raise RuntimeError, message, fn -> read_runtime_config() end

    # The ingest key alone grants no full access.
    System.put_env("GUARDIAN_INGEST_API_KEY", @key)
    assert_raise RuntimeError, message, fn -> read_runtime_config() end
  end

  test "rejects an empty API key" do
    for name <- ~w(GUARDIAN_API_KEY GUARDIAN_ADMIN_API_KEY GUARDIAN_INGEST_API_KEY) do
      System.put_env("GUARDIAN_API_KEY", @key)
      System.put_env(name, "")

      assert_raise RuntimeError, "#{name} must not be empty", fn ->
        read_runtime_config()
      end

      System.delete_env(name)
    end
  end

  test "loads the ingest and admin keys, each optional beside a full-access key" do
    ingest = String.duplicate("i", 32)
    admin = String.duplicate("a", 32)

    System.delete_env("GUARDIAN_API_KEY")
    System.put_env("GUARDIAN_ADMIN_API_KEY", admin)
    config = read_runtime_config()[:guardian]

    assert {config[:admin_api_key], config[:ingest_api_key], config[:api_key]} ==
             {admin, nil, nil}

    System.put_env("GUARDIAN_INGEST_API_KEY", ingest)
    config = read_runtime_config()[:guardian]

    assert {config[:admin_api_key], config[:ingest_api_key], config[:api_key]} ==
             {admin, ingest, nil}

    System.put_env("GUARDIAN_API_KEY", @key)
    config = read_runtime_config()[:guardian]

    assert {config[:admin_api_key], config[:ingest_api_key], config[:api_key]} ==
             {admin, ingest, @key}

    System.delete_env("GUARDIAN_ADMIN_API_KEY")
    config = read_runtime_config()[:guardian]

    assert {config[:admin_api_key], config[:ingest_api_key], config[:api_key]} ==
             {nil, ingest, @key}
  end

  test "rejects two API keys with the same value, never printing it" do
    message =
      "GUARDIAN_INGEST_API_KEY, GUARDIAN_ADMIN_API_KEY and GUARDIAN_API_KEY must all differ"

    pairs = [
      {"GUARDIAN_INGEST_API_KEY", "GUARDIAN_ADMIN_API_KEY"},
      {"GUARDIAN_INGEST_API_KEY", "GUARDIAN_API_KEY"},
      {"GUARDIAN_ADMIN_API_KEY", "GUARDIAN_API_KEY"},
    ]

    for {first, second} <- pairs do
      for name <- ~w(GUARDIAN_API_KEY GUARDIAN_ADMIN_API_KEY GUARDIAN_INGEST_API_KEY) do
        System.delete_env(name)
      end

      if first != "GUARDIAN_ADMIN_API_KEY" and second != "GUARDIAN_API_KEY" do
        System.put_env("GUARDIAN_API_KEY", String.duplicate("l", 32))
      end

      System.put_env(first, @key)
      System.put_env(second, @key)
      error = assert_raise RuntimeError, fn -> read_runtime_config() end
      assert error.message == message
      refute error.message =~ @key
    end
  end

  test "production reads GUARDIAN_DATA_DIR and creates the segment directory", %{
    directory: directory,
  } do
    System.put_env("GUARDIAN_API_KEY", @key)

    assert get_in(read_runtime_config(), [:guardian, :data_dir]) == directory
    assert File.dir?(Path.join(directory, "segments"))
    refute File.exists?(Path.join(directory, ".write_probe"))
  end

  test "production refuses an unwritable data directory", %{directory: directory} do
    System.put_env("GUARDIAN_API_KEY", @key)
    File.mkdir_p!(directory)
    File.write!(Path.join(directory, "file"), "")
    System.put_env("GUARDIAN_DATA_DIR", Path.join(directory, "file"))

    assert_raise RuntimeError, ~r/GUARDIAN_DATA_DIR .* is not writable/, fn ->
      read_runtime_config()
    end
  end

  test "on Fly, production refuses a data directory that is not a mounted volume", %{
    directory: directory,
  } do
    System.put_env("GUARDIAN_API_KEY", @key)
    System.put_env("FLY_PRIVATE_IP", "fdaa:0:1::2")
    File.mkdir_p!(directory)

    assert_raise RuntimeError, ~r/is not a mounted volume/, fn -> read_runtime_config() end
  end

  test "on Fly, production refuses a missing data directory", %{directory: directory} do
    System.put_env("GUARDIAN_API_KEY", @key)
    System.put_env("FLY_PRIVATE_IP", "fdaa:0:1::2")
    System.put_env("GUARDIAN_DATA_DIR", Path.join(directory, "missing"))

    assert_raise RuntimeError, ~r/is not a mounted volume/, fn -> read_runtime_config() end
    refute File.exists?(Path.join(directory, "missing"))
  end

  test "production enables DNS discovery only when a query is set" do
    System.put_env("GUARDIAN_API_KEY", @key)
    refute Keyword.has_key?(read_runtime_config()[:guardian], :dns_cluster_query)

    System.put_env("DNS_CLUSTER_QUERY", "my-app.internal")
    assert get_in(read_runtime_config(), [:guardian, :dns_cluster_query]) == "my-app.internal"
  end

  test "Storage uses the configured data directory" do
    assert Guardian.Storage.data_dir() == Application.fetch_env!(:guardian, :data_dir)
    assert Guardian.Storage.segment_dir() == Path.join(Guardian.Storage.data_dir(), "segments")
  end

  test "reads a positive mutable segment maximum age override" do
    System.put_env("GUARDIAN_API_KEY", @key)
    System.put_env("GUARDIAN_MUTABLE_SEGMENT_MAX_AGE_MS", "60000")

    assert get_in(read_runtime_config(), [:guardian, :mutable_segment_max_age_ms]) == 60_000
  end

  test "rejects invalid mutable segment age overrides" do
    System.put_env("GUARDIAN_API_KEY", @key)

    for value <- ["", "0", "-1", "1.5", "100ms"] do
      System.put_env("GUARDIAN_MUTABLE_SEGMENT_MAX_AGE_MS", value)

      assert_raise RuntimeError,
                   "GUARDIAN_MUTABLE_SEGMENT_MAX_AGE_MS must be a positive integer",
                   fn -> read_runtime_config() end
    end
  end

  test "rejects an API key shorter than 32 bytes" do
    for name <- ~w(GUARDIAN_API_KEY GUARDIAN_ADMIN_API_KEY GUARDIAN_INGEST_API_KEY),
        key <- ["k", String.duplicate("k", 31)] do
      for other <- ~w(GUARDIAN_ADMIN_API_KEY GUARDIAN_INGEST_API_KEY),
          do: System.delete_env(other)

      System.put_env("GUARDIAN_API_KEY", @key)
      System.put_env(name, key)

      assert_raise RuntimeError, ~r/^#{name} must be at least 32 bytes/, fn ->
        read_runtime_config()
      end
    end

    System.delete_env("GUARDIAN_ADMIN_API_KEY")
    System.delete_env("GUARDIAN_INGEST_API_KEY")

    # Bytes, not characters: 11 three-byte characters are 33 bytes.
    System.put_env("GUARDIAN_API_KEY", String.duplicate("€", 11))
    assert get_in(read_runtime_config(), [:guardian, :api_key]) == String.duplicate("€", 11)
  end

  test "ignores the removed GUARDIAN_ALLOW_QUERY_API_KEY" do
    System.put_env("GUARDIAN_API_KEY", @key)

    for value <- ["true", "false", "yes"] do
      System.put_env("GUARDIAN_ALLOW_QUERY_API_KEY", value)
      refute Keyword.has_key?(read_runtime_config()[:guardian], :allow_query_api_key)
    end
  end

  test "reads the query heap limit, where 0 turns it off" do
    System.put_env("GUARDIAN_API_KEY", @key)
    refute Keyword.has_key?(read_runtime_config()[:guardian], :query_max_heap_mb)

    for {value, expected} <- [{"0", 0}, {"512", 512}] do
      System.put_env("GUARDIAN_QUERY_MAX_HEAP_MB", value)
      assert get_in(read_runtime_config(), [:guardian, :query_max_heap_mb]) == expected
    end

    for value <- ["-1", "1.5", "lots"] do
      System.put_env("GUARDIAN_QUERY_MAX_HEAP_MB", value)
      assert_raise RuntimeError, ~r/GUARDIAN_QUERY_MAX_HEAP_MB must be/, &read_runtime_config/0
    end
  end

  test "reads the HTTP port" do
    System.put_env("GUARDIAN_API_KEY", @key)
    refute Keyword.has_key?(read_runtime_config()[:guardian], :http_port)

    System.put_env("GUARDIAN_PORT", "9090")
    assert get_in(read_runtime_config(), [:guardian, :http_port]) == 9090

    for value <- ["0", "65536", "http", "80.5"] do
      System.put_env("GUARDIAN_PORT", value)
      assert_raise RuntimeError, ~r/GUARDIAN_PORT must be/, &read_runtime_config/0
    end
  end

  defp read_runtime_config do
    Config.Reader.read!(@runtime_config, env: :prod, target: :host)
  end

  test "counter memory defaults to Store's 64 MiB and accepts positive MiB overrides" do
    System.put_env("GUARDIAN_API_KEY", @key)
    refute Keyword.has_key?(read_runtime_config()[:guardian], :counter_memory_budget_bytes)
    store = start_supervised!({Guardian.Counters.Store, name: nil})

    assert {:ok, %{memory_budget_bytes: 67_108_864}} =
             Guardian.Counters.Store.stats(server: store)

    for {value, mb} <- [{"1", 1}, {"128", 128}, {"+64", 64}] do
      System.put_env("GUARDIAN_COUNTER_MEMORY_MB", value)

      assert get_in(read_runtime_config(), [:guardian, :counter_memory_budget_bytes]) ==
               mb * 1_024 * 1_024
    end

    for value <- ["", "0", "-1", "1.5", "64MB", " 64", "64 "] do
      System.put_env("GUARDIAN_COUNTER_MEMORY_MB", value)

      assert_raise RuntimeError,
                   "GUARDIAN_COUNTER_MEMORY_MB must be a positive integer",
                   &read_runtime_config/0
    end
  end

  test "the configured counter byte budget reaches Store through application environment" do
    System.put_env("GUARDIAN_API_KEY", @key)
    System.put_env("GUARDIAN_COUNTER_MEMORY_MB", "2")
    budget = get_in(read_runtime_config(), [:guardian, :counter_memory_budget_bytes])
    Guardian.Test.Env.put(counter_memory_budget_bytes: budget)
    store = start_supervised!({Guardian.Counters.Store, name: nil})
    assert {:ok, %{memory_budget_bytes: 2_097_152}} = Guardian.Counters.Store.stats(server: store)
  end
end
