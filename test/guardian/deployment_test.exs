defmodule Guardian.DeploymentTest do
  use ExUnit.Case, async: true

  import Bitwise

  @release_env Path.expand("../../rel/env.sh.eex", __DIR__)

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
                         ERL_EPMD_ADDRESS RELEASE_TMP)

  # Sources rel/env.sh.eex in a shell with `env` (nil unsets) and returns
  # {status, output, changes}: changes maps each environment variable the script set
  # or changed to its new value, and to nil if it unset one. RELEASE_ROOT and HOME default
  # to a directory of the call's own.
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
          env:
            Enum.map(@release_env_inputs, &{&1, nil}) ++
              [{"RELEASE_ROOT", directory}, {"HOME", directory}] ++ env,
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
    assert map_size(changes) == 5
    assert changes["HOME"] =~ ~r{/tmp/cookie$}
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

  describe "the Erlang cookie" do
    @secret "cookie-3f9a7c"
    @server_commands ~w(start start_iex daemon daemon_iex)
    @client_commands ~w(remote rpc restart stop pid)

    setup %{directory: directory} do
      home = Path.join(directory, "home")
      File.mkdir_p!(home)
      {:ok, stat} = File.lstat(home)

      %{
        env: [
          {"RELEASE_ROOT", directory},
          {"HOME", home},
          {"GUARDIAN_NODE_HOST", "10.0.0.5"},
          {"RELEASE_COOKIE", @secret},
        ],
        home: home,
        server_home: Path.join(directory, "tmp/cookie"),
        client_home: Path.join(home, ".guardian-cookie-#{stat.uid}"),
      }
    end

    # Sourced as bin/guardian does, under set -e and with no `|| exit`.
    defp source_like_the_release(env) do
      script = ~S(set -e; . "$1"; echo started)

      System.cmd("sh", ["-c", script, "guardian-env", @release_env],
        env: Enum.map(@release_env_inputs, &{&1, nil}) ++ env,
        stderr_to_stdout: true
      )
    end

    defp mode(path) do
      File.stat!(path).mode &&& 0o777
    end

    defp assert_cookie_home(path, cookie) do
      assert File.read!(Path.join(path, ".erlang.cookie")) == cookie
      assert mode(Path.join(path, ".erlang.cookie")) == 0o600
      assert mode(path) == 0o700
      assert File.ls!(path) == [".erlang.cookie"]
    end

    test "the server's file is private and is its VM's HOME", context do
      for command <- @server_commands do
        env = [{"RELEASE_COMMAND", command} | context.env]
        assert {0, "", %{"HOME" => home}} = source_release_env(env)
        assert home == context.server_home
        assert_cookie_home(home, @secret)
      end
    end

    test "RELEASE_TMP moves the server's file", %{env: env, directory: directory} do
      tmp = Path.join(directory, "elsewhere")
      env = env ++ [{"RELEASE_COMMAND", "start"}, {"RELEASE_TMP", tmp}]

      assert {0, "", %{"HOME" => home}} = source_release_env(env)
      assert home == Path.join(tmp, "cookie")
      assert_cookie_home(home, @secret)
    end

    test "clients use their own file and leave the server's alone", context do
      assert {0, "", _} = source_release_env(context.env ++ [{"RELEASE_COMMAND", "start"}])
      refute File.exists?(context.client_home)

      for command <- @client_commands do
        env =
          List.keyreplace(context.env, "RELEASE_COOKIE", 0, {"RELEASE_COOKIE", "other"}) ++
            [{"RELEASE_COMMAND", command}]

        assert {0, "", %{"HOME" => home}} = source_release_env(env)
        assert home == context.client_home
        assert_cookie_home(home, "other")
      end

      assert_cookie_home(context.server_home, @secret)
    end

    # "/" stands for a HOME sudo kept from another user.
    test "a client without a HOME of its own uses a release tmp of its own", context do
      tmp = Path.join(context.directory, "tmp")
      File.mkdir_p!(tmp)

      for home <- ["", "/", Path.join(context.directory, "missing")] do
        env =
          List.keyreplace(context.env, "HOME", 0, {"HOME", home}) ++
            [{"RELEASE_COMMAND", "rpc"}]

        assert {0, "", %{"HOME" => cookie_home}} = source_release_env(env)
        assert Path.dirname(cookie_home) == tmp
        assert cookie_home =~ ~r{/\.guardian-cookie-\d+$}
        assert_cookie_home(cookie_home, @secret)
      end
    end

    test "a client doesn't take a symlink for its HOME", context do
      link = Path.join(context.directory, "link")
      File.ln_s!(context.home, link)
      File.mkdir_p!(Path.join(context.directory, "tmp"))
      env = List.keyreplace(context.env, "HOME", 0, {"HOME", link})

      assert {0, "", %{"HOME" => cookie_home}} =
               source_release_env(env ++ [{"RELEASE_COMMAND", "rpc"}])

      assert Path.dirname(cookie_home) == Path.join(context.directory, "tmp")
    end

    test "a client owning neither HOME nor the release's tmp refuses", context do
      home = {"HOME", "/"}
      env = List.keyreplace(context.env, "HOME", 0, home) ++ [{"RELEASE_COMMAND", "rpc"}]

      # Absent: the service's first start must still be able to create it.
      assert {output, 1} = source_like_the_release(env)
      assert output =~ "HOME must be a directory owned by the user running this command"
      refute File.exists?(Path.join(context.directory, "tmp"))

      # Someone else's.
      assert {output, 1} = source_like_the_release(env ++ [{"RELEASE_TMP", "/usr"}])
      assert output =~ "HOME must be a directory owned by the user running this command"
      refute output =~ @secret
    end

    test "commands without distribution write nothing and keep HOME", context do
      for command <- [nil, "eval", "version"] do
        env = context.env ++ [{"RELEASE_COMMAND", command}]
        assert {0, "", changes} = source_release_env(env)
        refute Map.has_key?(changes, "HOME")
      end

      assert File.ls!(context.home) == []
      refute File.exists?(context.server_home)
    end

    test "a single node copies the cookie built into the release", context do
      File.mkdir_p!(Path.join(context.directory, "releases"))
      File.write!(Path.join(context.directory, "releases/COOKIE"), "built-in")

      env = [
        {"RELEASE_ROOT", context.directory},
        {"HOME", context.home},
        {"RELEASE_COMMAND", "start"},
      ]

      assert {0, "", %{"HOME" => home}} = source_release_env(env)
      assert_cookie_home(home, "built-in")
    end

    test "it works under set -e, as bin/guardian sources it", context do
      env = context.env ++ [{"RELEASE_COMMAND", "start"}]
      assert {"started
", 0} = source_like_the_release(env)
      assert_cookie_home(context.server_home, @secret)
    end

    test "with nothing to write it refuses to start, printing no cookie", context do
      # The release's tmp directory can't be created: a file is in the way.
      File.write!(Path.join(context.directory, "tmp"), "")
      env = context.env ++ [{"RELEASE_COMMAND", "start"}]

      assert {output, 1} = source_like_the_release(env)
      assert output =~ "Could not write the Erlang cookie file in"
      refute output =~ "started"
      refute output =~ @secret

      # No cookie at all, and no file to take one from.
      env = [
        {"RELEASE_ROOT", context.home},
        {"HOME", context.home},
        {"RELEASE_COOKIE", ""},
        {"RELEASE_COMMAND", "rpc"},
      ]

      assert {output, 1} = source_like_the_release(env)
      assert output =~ "Could not write the Erlang cookie file in"
      refute output =~ "started"
    end

    test "a symlink at the path is refused, and its target left alone", context do
      target = Path.join(context.directory, "target")
      File.mkdir_p!(target)
      File.chmod!(target, 0o755)
      File.ln_s!(target, context.client_home)

      assert {output, 1} = source_like_the_release(context.env ++ [{"RELEASE_COMMAND", "rpc"}])
      assert output =~ "Could not write the Erlang cookie file in"
      refute output =~ @secret
      assert mode(target) == 0o755
      assert File.ls!(target) == []
    end

    # What the file is for: with no -setcookie, OTP takes the cookie from it.
    test "OTP reads the cookie from the file", context do
      env = context.env ++ [{"RELEASE_COMMAND", "start"}]
      assert {0, "", %{"HOME" => home}} = source_release_env(env)

      node = "guardian_cookie_test_#{System.pid()}_#{System.unique_integer([:positive])}"
      eval = "io:put_chars(atom_to_list(erlang:get_cookie())), halt()."

      assert {@secret, 0} =
               System.cmd("erl", ["-noshell", "-sname", node, "-eval", eval],
                 env: [
                   {"HOME", home},
                   {"ERL_AFLAGS", nil},
                   {"ERL_FLAGS", nil},
                   {"ERL_ZFLAGS", nil},
                   {"ERL_EPMD_ADDRESS", nil},
                 ]
               )
    end

    test "the release's script passes no cookie on any command line" do
      script = Mix.Tasks.Release.Init.cli_text()
      assert script =~ ~S(--cookie "$RELEASE_COOKIE")

      stripped = Guardian.MixProject.remove_cookie_args_from_script(script)
      refute stripped =~ "--cookie"
      refute stripped =~ "-setcookie"

      # Only the arguments went: every other line of the script survives.
      assert stripped =~ ~s(--hidden \\\n)
      assert stripped =~ ~S(--rpc-eval "$RELEASE_NODE" "$1")
      assert stripped =~ ~S(--remsh "$RELEASE_NODE")
    end

    test "a release script passing the cookie another way fails the build" do
      for script <- [
            ~S(exec elixir --cookie "${RELEASE_COOKIE}"),
            ~S(exec elixir --cookie "$RELEASE_COOKIE" --erl "-setcookie x"),
            "exec elixir",
          ] do
        assert_raise Mix.Error, fn ->
          Guardian.MixProject.remove_cookie_args_from_script(script)
        end
      end
    end

    test "nothing in rel/ sets the cookie on the command line" do
      paths = Path.wildcard(Path.expand("../../rel/*vm.args.eex", __DIR__))
      assert length(paths) == 2

      for path <- [@release_env | paths] do
        refute File.read!(path) =~ ~r/^[^#]*-setcookie/m
      end
    end

    test "the release runs the step that takes the cookie arguments out" do
      steps = Mix.Project.config()[:releases][:guardian][:steps]

      assert [:assemble, &Guardian.MixProject.remove_cookie_args/1] ==
               Enum.drop_while(steps, &(&1 != :assemble))
    end
  end

  describe "the Fly guide" do
    setup do
      guide = File.read!(Path.expand("../../docs/guides/fly.md", __DIR__))

      # The fenced block after the marker holds the settings the reader adds to the
      # fly.toml that fly launch writes.
      settings = Regex.run(~r/<!-- fly-toml-settings -->\n```toml\n(.*?)\n```/s, guide)
      assert settings, "the guide lost its marked fly.toml settings block"

      launch = Regex.run(~r/^fly launch (?:.*\\\n)*.*$/m, guide)
      assert launch, "the guide lost its fly launch command"

      %{guide: guide, settings: Enum.at(settings, 1), launch: hd(launch)}
    end

    # Fly's kill_timeout must stay above Storage's shutdown budget plus the tunnel
    # connector's drain (bin/fly-start), and Guardian saves its in-memory segments only
    # on SIGTERM.
    test "its kill_timeout covers the shutdown", %{settings: settings} do
      assert settings == ~s(kill_signal = "SIGTERM"\nkill_timeout = 150)
    end

    # Without the flag, fly launch in a GitHub clone writes a deploy workflow and can
    # store a long-lived deploy token as a repository secret.
    test "fly launch sets up no GitHub workflow", %{launch: launch} do
      assert launch =~ "--no-github-workflow"
    end

    # A deployment gets Guardian's defaults: the image sets the data directory,
    # fly launch sets no environment variables, and nothing in the guide adds an
    # [env] section to fly.toml.
    test "it sets no Guardian setting", %{launch: launch, guide: guide} do
      refute launch =~ ~r/(--env|\s-e)[ =]/
      refute guide =~ ~r/^\[env\]/m

      dockerfile = File.read!(Path.expand("../../Dockerfile", __DIR__))
      assert dockerfile =~ ~r{^ENV GUARDIAN_DATA_DIR=/data$}m
    end
  end

  describe "fly-start" do
    @fly_start Path.expand("../../bin/fly-start", __DIR__)

    # Fakes for bin/guardian and cloudflared. Each appends what happens to it to
    # events.log. Before the script starts, a fake /proc/net/tcp6 holds only decoys:
    # port 8080 not listening, and port 8081 listening. The fake Guardian records its
    # PID, then "listens" by adding a LISTEN line for $GUARDIAN_PORT (default 8080) to
    # $FAKE_LISTEN_TABLE (default tcp6). FAKE_GUARDIAN picks its behavior: exit-early
    # exits 7 at once, never-listen never listens, exit-later exits 5 once the
    # connector has started, exit-during-drain exits 6 once the connector is draining;
    # otherwise it runs until SIGTERM and exits 3.
    # FAKE_CLOUDFLARED: crash exits at once every time, crash-once exits at once the
    # first time only, hang ignores SIGTERM; otherwise it drains on SIGTERM and exits.
    defp fly_start_fakes(directory) do
      log = Path.join(directory, "events.log")
      proc_net = Path.join(directory, "proc_net")
      File.mkdir_p!(proc_net)
      zero = String.duplicate("0", 32)

      File.write!(Path.join(proc_net, "tcp6"), """
        sl  local_address                         rem_address                           st
         0: #{zero}:1F90 #{zero}:0000 06
         1: #{zero}:1F91 #{zero}:0000 0A
      """)

      write_executable(directory, "guardian", """
      #!/bin/sh
      trap 'echo "guardian term" >> "#{log}"; exit 3' TERM
      echo $$ > "#{directory}/guardian.pid"
      echo "guardian $1 token=${TUNNEL_TOKEN:-none}" >> "#{log}"
      case "${FAKE_GUARDIAN:-}" in
        exit-early) echo "guardian exit" >> "#{log}"; exit 7 ;;
        never-listen) while :; do sleep 0.1; done ;;
      esac
      sleep 0.5
      echo "guardian listening" >> "#{log}"
      port=$(printf '%04X' "${GUARDIAN_PORT:-8080}")
      printf '   2: %s:%s %s:0000 0A\\n' #{zero} "$port" #{zero} \\
        >> "#{proc_net}/${FAKE_LISTEN_TABLE:-tcp6}"
      if [ "${FAKE_GUARDIAN:-}" = exit-during-drain ]; then
        until grep -q '^cloudflared term' "#{log}"; do sleep 0.02; done
        echo "guardian exit" >> "#{log}"
        exit 6
      fi
      if [ "${FAKE_GUARDIAN:-}" = exit-later ]; then
        until grep -q '^cloudflared start' "#{log}"; do sleep 0.1; done
        echo "guardian exit" >> "#{log}"
        exit 5
      fi
      while :; do sleep 0.1; done
      """)

      write_executable(directory, "cloudflared", """
      #!/bin/sh
      if [ "${FAKE_CLOUDFLARED:-}" = hang ]; then
        trap 'echo "cloudflared term ignored" >> "#{log}"' TERM
      else
        trap 'echo "cloudflared term" >> "#{log}"; sleep 0.3; echo "cloudflared exit" >> "#{log}"; exit 0' TERM
      fi
      echo "cloudflared start $* token=$TUNNEL_TOKEN" >> "#{log}"
      crashed="#{directory}/cloudflared.crashed"
      if [ "${FAKE_CLOUDFLARED:-}" = crash ] ||
         { [ "${FAKE_CLOUDFLARED:-}" = crash-once ] && [ ! -f "$crashed" ]; }; then
        touch "$crashed"
        echo "cloudflared exit" >> "#{log}"
        exit 1
      fi
      while :; do sleep 0.1; done
      """)

      env = [
        {"GUARDIAN_START_BIN", Path.join(directory, "guardian")},
        {"CLOUDFLARED_BIN", Path.join(directory, "cloudflared")},
        {"FLY_START_PROC_NET", proc_net},
        {"FLY_START_CONNECTOR_KILL_AFTER", nil},
        {"GUARDIAN_PORT", nil},
        {"GUARDIAN_TUNNEL", nil},
        {"FAKE_GUARDIAN", nil},
        {"FAKE_CLOUDFLARED", nil},
        {"FAKE_LISTEN_TABLE", nil},
        {"TUNNEL_TOKEN", nil},
      ]

      {env, log}
    end

    # Starts bin/fly-start with `overrides` on top of `env`, returning the task that
    # yields {output, status} and the script's PID.
    defp start_fly_start(directory, env, overrides) do
      env = Enum.reduce(overrides, env, fn {k, v}, acc -> List.keystore(acc, k, 0, {k, v}) end)
      pid_file = Path.join(directory, "fly-start.pid")

      task =
        Task.async(fn ->
          System.cmd("sh", ["-c", ~S(echo $$ > "$0"; exec sh "$1"), pid_file, @fly_start],
            env: env,
            stderr_to_stdout: true
          )
        end)

      Guardian.Test.Polling.eventually(
        fn -> File.exists?(pid_file) and File.read!(pid_file) =~ ~r/^\d+\n$/ end,
        10_000
      )

      pid = pid_file |> File.read!() |> String.trim()

      # If a test fails before the script ends, kill the fakes it started: only
      # processes whose command line names this test's own directory. The script then
      # ends on its own, as Guardian is gone.
      pattern = String.replace(directory <> "/", ".", "\\.")
      on_exit(fn -> System.cmd("pkill", ["-KILL", "-f", pattern], stderr_to_stdout: true) end)

      {task, pid}
    end

    defp run_fly_start(directory, env, overrides) do
      {task, _pid} = start_fly_start(directory, env, overrides)
      Task.await(task, 20_000)
    end

    defp events(log) do
      if File.exists?(log), do: log |> File.read!() |> String.split("\n", trim: true), else: []
    end

    defp wait_for_event(log, prefix) do
      Guardian.Test.Polling.eventually(
        fn -> Enum.any?(events(log), &String.starts_with?(&1, prefix)) end,
        10_000
      )
    end

    defp signal(pid, name) do
      {_, 0} = System.cmd("kill", ["-#{name}", pid])
    end

    @connector_start "cloudflared start --no-autoupdate tunnel --metrics 127.0.0.1:20241 " <>
                       "--management-diagnostics=false --grace-period 10s run " <>
                       "token=tunnel-secret"

    test "without a tunnel token execs Guardian", %{directory: directory} do
      {env, log} = fly_start_fakes(directory)
      {task, pid} = start_fly_start(directory, env, [{"FAKE_GUARDIAN", "exit-early"}])

      assert {"", 7} = Task.await(task, 20_000)
      assert events(log) == ["guardian start token=none", "guardian exit"]
      # Same process: the script replaced itself with Guardian.
      assert File.read!(Path.join(directory, "guardian.pid")) == pid <> "\n"
    end

    test "GUARDIAN_TUNNEL=off starts only Guardian, without the token", %{
      directory: directory,
    } do
      {env, log} = fly_start_fakes(directory)

      overrides = [
        {"TUNNEL_TOKEN", "tunnel-secret"},
        {"GUARDIAN_TUNNEL", "off"},
        {"FAKE_GUARDIAN", "exit-early"},
      ]

      assert {"", 7} = run_fly_start(directory, env, overrides)
      assert events(log) == ["guardian start token=none", "guardian exit"]
    end

    test "starts the connector once Guardian listens, and drains it before stopping " <>
           "Guardian on SIGTERM",
         %{directory: directory} do
      {env, log} = fly_start_fakes(directory)
      {task, pid} = start_fly_start(directory, env, [{"TUNNEL_TOKEN", "tunnel-secret"}])

      wait_for_event(log, "cloudflared start")
      signal(pid, "TERM")

      assert {"", 3} = Task.await(task, 20_000)

      assert events(log) == [
               "guardian start token=none",
               "guardian listening",
               @connector_start,
               "cloudflared term",
               "cloudflared exit",
               "guardian term",
             ]
    end

    test "SIGINT drains the connector too, and the IPv4 table and GUARDIAN_PORT count",
         %{directory: directory} do
      {env, log} = fly_start_fakes(directory)

      {task, pid} =
        start_fly_start(directory, env, [
          {"TUNNEL_TOKEN", "tunnel-secret"},
          {"GUARDIAN_PORT", "9090"},
          {"FAKE_LISTEN_TABLE", "tcp"},
        ])

      wait_for_event(log, "cloudflared start")
      signal(pid, "INT")

      assert {"", 3} = Task.await(task, 20_000)

      assert events(log) == [
               "guardian start token=none",
               "guardian listening",
               @connector_start,
               "cloudflared term",
               "cloudflared exit",
               "guardian term",
             ]
    end

    test "a connector that ignores SIGTERM is killed, then Guardian stops", %{
      directory: directory,
    } do
      {env, log} = fly_start_fakes(directory)

      {task, pid} =
        start_fly_start(directory, env, [
          {"TUNNEL_TOKEN", "tunnel-secret"},
          {"FAKE_CLOUDFLARED", "hang"},
          {"FLY_START_CONNECTOR_KILL_AFTER", "1"},
        ])

      wait_for_event(log, "cloudflared start")
      signal(pid, "TERM")

      # The shell may report the kill ("Killed: 9").
      assert {_output, 3} = Task.await(task, 20_000)

      assert events(log) == [
               "guardian start token=none",
               "guardian listening",
               @connector_start,
               "cloudflared term ignored",
               "guardian term",
             ]
    end

    test "a connector that exits is started again", %{directory: directory} do
      {env, log} = fly_start_fakes(directory)

      {task, pid} =
        start_fly_start(directory, env, [
          {"TUNNEL_TOKEN", "tunnel-secret"},
          {"FAKE_CLOUDFLARED", "crash-once"},
        ])

      Guardian.Test.Polling.eventually(
        fn -> Enum.count(events(log), &(&1 == @connector_start)) == 2 end,
        10_000
      )

      signal(pid, "TERM")

      assert {"", 3} = Task.await(task, 20_000)

      assert events(log) == [
               "guardian start token=none",
               "guardian listening",
               @connector_start,
               "cloudflared exit",
               @connector_start,
               "cloudflared term",
               "cloudflared exit",
               "guardian term",
             ]
    end

    test "Guardian exiting while the connector drains passes on its status", %{
      directory: directory,
    } do
      {env, log} = fly_start_fakes(directory)

      {task, pid} =
        start_fly_start(directory, env, [
          {"TUNNEL_TOKEN", "tunnel-secret"},
          {"FAKE_GUARDIAN", "exit-during-drain"},
        ])

      wait_for_event(log, "cloudflared start")
      signal(pid, "TERM")

      assert {"", 6} = Task.await(task, 20_000)

      assert events(log) == [
               "guardian start token=none",
               "guardian listening",
               @connector_start,
               "cloudflared term",
               "guardian exit",
               "cloudflared exit",
             ]
    end

    test "Guardian exiting before it listens ends the script with its status", %{
      directory: directory,
    } do
      {env, log} = fly_start_fakes(directory)
      overrides = [{"TUNNEL_TOKEN", "tunnel-secret"}, {"FAKE_GUARDIAN", "exit-early"}]

      assert {"", 7} = run_fly_start(directory, env, overrides)
      assert events(log) == ["guardian start token=none", "guardian exit"]
    end

    test "SIGTERM before Guardian listens stops Guardian and starts no connector", %{
      directory: directory,
    } do
      {env, log} = fly_start_fakes(directory)

      {task, pid} =
        start_fly_start(directory, env, [
          {"TUNNEL_TOKEN", "tunnel-secret"},
          {"FAKE_GUARDIAN", "never-listen"},
        ])

      wait_for_event(log, "guardian start")
      # Long enough for the connector loop to check the decoys more than once.
      Process.sleep(2_500)
      signal(pid, "TERM")

      assert {"", 3} = Task.await(task, 20_000)
      assert events(log) == ["guardian start token=none", "guardian term"]
    end

    test "SIGTERM while the connector waits to restart starts no new connector", %{
      directory: directory,
    } do
      {env, log} = fly_start_fakes(directory)

      {task, pid} =
        start_fly_start(directory, env, [
          {"TUNNEL_TOKEN", "tunnel-secret"},
          {"FAKE_CLOUDFLARED", "crash"},
        ])

      wait_for_event(log, "cloudflared exit")
      started = System.monotonic_time(:millisecond)
      signal(pid, "TERM")

      assert {"", 3} = Task.await(task, 20_000)
      # Well inside the 5 s pause: the pause was cut short, not waited out.
      assert System.monotonic_time(:millisecond) - started < 4_000

      assert events(log) == [
               "guardian start token=none",
               "guardian listening",
               @connector_start,
               "cloudflared exit",
               "guardian term",
             ]
    end

    test "Guardian exiting on its own stops the connector and passes on its status", %{
      directory: directory,
    } do
      {env, log} = fly_start_fakes(directory)
      overrides = [{"TUNNEL_TOKEN", "tunnel-secret"}, {"FAKE_GUARDIAN", "exit-later"}]

      assert {"", 5} = run_fly_start(directory, env, overrides)

      assert events(log) == [
               "guardian start token=none",
               "guardian listening",
               @connector_start,
               "guardian exit",
               "cloudflared term",
               "cloudflared exit",
             ]
    end
  end

  defp write_executable(directory, name, contents) do
    path = Path.join(directory, name)
    File.write!(path, contents)
    File.chmod!(path, 0o700)
  end
end
