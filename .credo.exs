# Credo runs one check: every alias on its own line (CONTRIBUTING.md, "Elixir style").
# The pre-commit hook runs `mix credo`. Enable another check only by deciding to.
%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["*.exs", ".formatter.exs", "config/", "lib/", "libtest/", "test/"],
        excluded: [],
      },
      # MultiAlias has low priority, which Credo reports only in strict mode.
      strict: true,
      checks: %{
        enabled: [
          {Credo.Check.Readability.MultiAlias, []},
        ],
      },
    },
  ],
}
