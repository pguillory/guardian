defmodule MixProject do
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
        guardian: [],
      ],
      aliases: aliases(),
      # Scripts that tests run in child processes, not test files.
      test_ignore_filters: [&String.starts_with?(&1, "test/fixtures/")],
    ]
  end

  defp aliases do
    [
      format: [
        "format",
        fn _ -> Mix.Task.reenable("format") end,
        "format",
      ],
    ]
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
      mod: {Main, []},
      extra_applications: [:logger, :runtime_tools],
    ]
  end

  defp deps do
    [
      {:anubis_mcp, "== 0.16.0"},
      {:bandit, ">= 0.0.0"},
      {:benchee, ">= 0.0.0", only: :dev},
      {:cors_plug, ">= 0.0.0"},
      {:dns_cluster, "~> 0.3"},
      {:elixir_make, ">= 0.0.0", runtime: false},
      {:exsync, ">= 0.0.0", only: :dev},
      {:freedom_formatter, ">= 0.0.0", only: :dev},
      {:hypex, "~> 1.1"},
      {:hyperscan, ">= 0.0.0"},
      {:jason, ">= 0.0.0"},
      {:superlist, ">= 0.0.0"},
      {:uuid, ">= 0.0.0"},
    ]
  end
end
