defmodule Guardian.MixProject do
  use Mix.Project

  def project do
    [
      app: :guardian,
      version: "0.1.0",
      elixir: "~> 1.16",
      compilers: [:elixir_make] ++ Mix.compilers(),
      elixirc_paths: elixirc_paths(),
      elixirc_options: elixirc_options(),
      make_targets: ["nifs"],
      make_clean: ["clean"],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      default_release: :guardian,
      releases: [
        guardian: [
          steps: [
            &__MODULE__.require_prod_release/1,
            :assemble,
            &__MODULE__.remove_cookie_args/1,
          ],
        ],
      ],
      # Scripts that tests run in child processes, not test files.
      test_ignore_filters: [&String.starts_with?(&1, "test/fixtures/")],
    ]
  end

  # Only MIX_ENV=prod builds a release. config/runtime.exs generates an admin key when
  # none is set in dev, and a release keeps the MIX_ENV it was built with, so a dev
  # release would boot without a key.
  def require_prod_release(release, env \\ Mix.env()) do
    if env != :prod do
      Mix.raise("Guardian releases must be built with MIX_ENV=prod, not #{env}")
    end

    release
  end

  # A release step: the generated bin/guardian puts the Erlang cookie on every VM's
  # command line, and Mix has no option against that. rel/env.sh.eex gives the VM the
  # cookie in a private file instead.
  def remove_cookie_args(release) do
    path = Path.join([release.path, "bin", Atom.to_string(release.name)])
    File.write!(path, remove_cookie_args_from_script(File.read!(path)))
    release
  end

  # Fails the build if Mix's script changes, so that an upgrade can't quietly put the
  # cookie back on the command line.
  def remove_cookie_args_from_script(script) do
    argument = ~S(--cookie "$RELEASE_COOKIE" )
    stripped = String.replace(script, argument, "")

    if stripped == script or String.contains?(stripped, ["--cookie", "-setcookie"]) do
      Mix.raise("Mix's release script changed: #{argument} should be its only cookie argument")
    end

    stripped
  end

  def elixirc_paths do
    case Mix.env() do
      :test -> ["lib", "libtest"]
      _ -> ["lib"]
    end
  end

  def elixirc_options do
    case Mix.env() do
      :test -> [warnings_as_errors: true]
      _ -> []
    end
  end

  def application do
    [
      mod: {Guardian.Application, []},
      extra_applications: [:logger, :runtime_tools, :xmerl],
    ]
  end

  defp deps do
    [
      {:anubis_mcp, "== 2.2.0"},
      {:bandit, ">= 0.0.0"},
      {:cors_plug, ">= 0.0.0"},
      {:credo, "~> 1.7", only: :dev, runtime: false},
      {:dns_cluster, "~> 0.3"},
      {:elixir_make, ">= 0.0.0", runtime: false},
      {:exsync, ">= 0.0.0", only: :dev},
      {:freedom_formatter, ">= 0.0.0", only: :dev},
      {:hypex, "~> 1.1"},
      {:jason, ">= 0.0.0"},
      {:req, "~> 0.7"},
      {:superlist, ">= 0.0.0"},
      {:uuid, ">= 0.0.0"},
    ]
  end
end
