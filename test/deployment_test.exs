defmodule DeploymentTest do
  use ExUnit.Case, async: true

  @release_env Path.expand("../rel/env.sh.eex", __DIR__)

  setup do
    directory =
      Path.join(
        System.tmp_dir!(),
        "guardian_deployment_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    %{directory: directory}
  end

  # Inputs the script reads, unset unless a test sets them.
  @release_env_inputs ~w(FLY_PRIVATE_IP FLY_APP_NAME GUARDIAN_NODE_HOST DNS_CLUSTER_QUERY
                         RELEASE_COOKIE ERL_AFLAGS GUARDIAN_DIST_PORT RELEASE_COMMAND
                         ERL_EPMD_ADDRESS)

  # Sources rel/env.sh.eex in a shell with `env` (nil unsets) and returns
  # {status, output, changes}: changes maps each environment variable the script set
  # or changed to its new value, and to nil if it unset one.
  defp source_release_env(env, command \\ "true") do
    script = """
    env | sort > "$2/before"
    . "$1" || exit $?
    #{command}
    env | sort > "$2/after"
    """

    directory = Path.join(System.tmp_dir!(), "guardian_env_#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)

    try do
      {output, status} =
        System.cmd("sh", ["-c", script, "guardian-env", @release_env, directory],
          env: Enum.map(@release_env_inputs, &{&1, nil}) ++ env,
          stderr_to_stdout: true
        )

      changes =
        if status == 0 do
          before = read_env(Path.join(directory, "before"))
          after_ = read_env(Path.join(directory, "after"))

          for name <- Enum.uniq(Map.keys(before) ++ Map.keys(after_)),
              before[name] != after_[name],
              into: %{},
              do: {name, after_[name]}
        end

      {status, output, changes}
    after
      File.rm_rf!(directory)
    end
  end

  defp read_env(path) do
    for line <- String.split(File.read!(path), "\n", trim: true),
        [name, value] <- [String.split(line, "=", parts: 2)],
        into: %{},
        do: {name, value}
  end

  test "a single node is guardian@localhost with distribution on loopback only" do
    assert {0, "", changes} = source_release_env([])

    assert changes == %{
             "RELEASE_DISTRIBUTION" => "sname",
             "RELEASE_NODE" => "guardian@localhost",
             "ERL_EPMD_ADDRESS" => "127.0.0.1",
             "ERL_AFLAGS" => "-kernel inet_dist_use_interface {127,0,0,1}",
           }
  end

  # Production's environment, exactly: no variable besides these changes on Fly.
  test "on Fly the node is guardian@<private IPv6> with DNS discovery of <app>.internal" do
    env = [
      {"FLY_PRIVATE_IP", "fdaa:0:1::2"},
      {"FLY_APP_NAME", "my-app"},
      {"RELEASE_COOKIE", "cookie"},
      {"ERL_AFLAGS", "+sbwt none"},
    ]

    assert {0, "", changes} = source_release_env(env)

    assert changes == %{
             "RELEASE_DISTRIBUTION" => "name",
             "RELEASE_NODE" => "guardian@fdaa:0:1::2",
             "ERL_AFLAGS" => "+sbwt none -proto_dist inet6_tcp",
             "DNS_CLUSTER_QUERY" => "my-app.internal",
           }

    # Without ERL_AFLAGS, and with a start command, the same.
    env = List.keydelete(env, "ERL_AFLAGS", 0) ++ [{"RELEASE_COMMAND", "start"}]
    assert {0, "", changes} = source_release_env(env)
    assert changes["ERL_AFLAGS"] == "-proto_dist inet6_tcp"
    assert map_size(changes) == 4
  end

  test "on Fly, settings the operator made win over the preset" do
    base = [
      {"FLY_PRIVATE_IP", "fdaa:0:1::2"},
      {"FLY_APP_NAME", "my-app"},
      {"RELEASE_COOKIE", "c"},
    ]

    assert {0, "", changes} =
             source_release_env(base ++ [{"DNS_CLUSTER_QUERY", "other.internal"}])

    refute Map.has_key?(changes, "DNS_CLUSTER_QUERY")

    assert {0, "", changes} = source_release_env(base ++ [{"GUARDIAN_NODE_HOST", "fdaa:0:1::9"}])
    assert changes["RELEASE_NODE"] == "guardian@fdaa:0:1::9"
  end

  test "on Fly without an app name, discovery stays off" do
    env = [{"FLY_PRIVATE_IP", "fdaa:0:1::2"}, {"RELEASE_COOKIE", "cookie"}]
    assert {0, "", changes} = source_release_env(env)
    refute Map.has_key?(changes, "DNS_CLUSTER_QUERY")
  end

  test "on Fly, a node without a cookie refuses to start" do
    for cookie <- [nil, ""] do
      env = [
        {"FLY_PRIVATE_IP", "fdaa:0:1::2"},
        {"FLY_APP_NAME", "my-app"},
        {"RELEASE_COOKIE", cookie},
      ]

      assert {status, output, nil} = source_release_env(env, "echo started")
      assert status != 0
      assert output =~ "RELEASE_COOKIE must be set (fly secrets set RELEASE_COOKIE=...)"
      refute output =~ "started"
    end
  end

  test "GUARDIAN_NODE_HOST names a cluster member, with the address family it implies" do
    env = [{"GUARDIAN_NODE_HOST", "10.0.0.5"}, {"RELEASE_COOKIE", "cookie"}]
    assert {0, "", changes} = source_release_env(env ++ [{"DNS_CLUSTER_QUERY", "guardian-peers"}])

    assert changes == %{"RELEASE_DISTRIBUTION" => "name", "RELEASE_NODE" => "guardian@10.0.0.5"}

    env = [{"GUARDIAN_NODE_HOST", "fd00::5"}, {"RELEASE_COOKIE", "cookie"}]
    assert {0, "", changes} = source_release_env(env)

    assert changes == %{
             "RELEASE_DISTRIBUTION" => "name",
             "RELEASE_NODE" => "guardian@fd00::5",
             "ERL_AFLAGS" => "-proto_dist inet6_tcp",
           }
  end

  test "GUARDIAN_NODE_HOST without a cookie refuses to start" do
    for cookie <- [nil, ""] do
      env = [{"GUARDIAN_NODE_HOST", "10.0.0.5"}, {"RELEASE_COOKIE", cookie}]
      assert {status, output, nil} = source_release_env(env, "echo started")
      assert status != 0
      assert output =~ "RELEASE_COOKIE must be set when GUARDIAN_NODE_HOST is set"
      refute output =~ "started"
    end
  end

  test "GUARDIAN_DIST_PORT pins the server's distribution port, not a client's" do
    env = [
      {"GUARDIAN_NODE_HOST", "10.0.0.5"},
      {"RELEASE_COOKIE", "c"},
      {"GUARDIAN_DIST_PORT", "9100"},
    ]

    for command <- ~w(start start_iex daemon daemon_iex) do
      assert {0, "", changes} = source_release_env([{"RELEASE_COMMAND", command} | env])

      assert changes["ERL_AFLAGS"] ==
               "-kernel inet_dist_listen_min 9100 inet_dist_listen_max 9100"
    end

    for command <- ~w(remote rpc eval) do
      assert {0, "", changes} = source_release_env([{"RELEASE_COMMAND", command} | env])
      refute Map.has_key?(changes, "ERL_AFLAGS")
    end

    for port <- ["0", "65536", "91a", "-1"] do
      env = List.keyreplace(env, "GUARDIAN_DIST_PORT", 0, {"GUARDIAN_DIST_PORT", port})
      assert {status, output, nil} = source_release_env([{"RELEASE_COMMAND", "start"} | env])
      assert status != 0
      assert output =~ "GUARDIAN_DIST_PORT must be a port number"
    end
  end

  # The maintainer's deployment keeps its pre-existing behavior through these overrides;
  # dropping one by accident would change production at the next deploy.
  test "fly.toml keeps this deployment's overrides active" do
    fly_toml = File.read!(Path.expand("../fly.toml", __DIR__))
    assert fly_toml =~ ~r/^  GUARDIAN_ALLOW_QUERY_API_KEY = "true"$/m
    assert fly_toml =~ ~r/^  GUARDIAN_QUERY_MAX_HEAP_MB = "0"$/m
    assert fly_toml =~ ~r/^kill_timeout = 120$/m
  end

  describe "fly-start" do
    @fly_start Path.expand("../bin/fly-start", __DIR__)

    # Fakes for bin/guardian and cloudflared. The fake connector records what it
    # was given and ends its restart loop; the fake Guardian waits briefly for
    # that record, then reports its own environment.
    defp fly_start_fakes(directory) do
      marker = Path.join(directory, "cloudflared.out")

      write_executable(
        directory,
        "cloudflared",
        "#!/bin/sh\nprintf '%s token=%s\\n' \"$*\" \"$TUNNEL_TOKEN\" > '#{marker}'\nkill $PPID\n"
      )

      write_executable(directory, "guardian", """
      #!/bin/sh
      i=0
      while [ ! -f '#{marker}' ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
      printf 'guardian %s token=%s\\n' "$1" "${TUNNEL_TOKEN:-none}"
      """)

      [
        {"GUARDIAN_START_BIN", Path.join(directory, "guardian")},
        {"CLOUDFLARED_BIN", Path.join(directory, "cloudflared")},
      ]
    end

    test "without a tunnel token starts only Guardian", %{directory: directory} do
      env = fly_start_fakes(directory)

      assert {"guardian start token=none\n", 0} =
               System.cmd("sh", [@fly_start], env: [{"TUNNEL_TOKEN", nil} | env])

      refute File.exists?(Path.join(directory, "cloudflared.out"))
    end

    test "with a tunnel token starts the connector, which alone keeps the token", %{
      directory: directory,
    } do
      env = fly_start_fakes(directory)

      assert {"guardian start token=none\n", 0} =
               System.cmd("sh", [@fly_start], env: [{"TUNNEL_TOKEN", "tunnel-secret"} | env])

      assert File.read!(Path.join(directory, "cloudflared.out")) ==
               "--no-autoupdate tunnel --metrics 127.0.0.1:20241 " <>
                 "--management-diagnostics=false run token=tunnel-secret\n"
    end
  end

  defp write_executable(directory, name, contents) do
    path = Path.join(directory, name)
    File.write!(path, contents)
    File.chmod!(path, 0o700)
  end
end
