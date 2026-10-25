defmodule Guardian.Web.MCP.QueryLanguageTest do
  use ExUnit.Case, async: true

  @reference File.read!("lib/guardian/web/mcp/query_language.md")

  test "documents every registered function and aggregate" do
    # `interval` is registered for the INTERVAL n UNIT syntax, but INTERVAL is a keyword,
    # so interval(...) cannot be called directly. `test_raise` exists only in the test build.
    names =
      Enum.uniq(Guardian.Query.Function.names() ++ Guardian.Aggregation.names()) --
        ["interval", "test_raise"]

    missing =
      Enum.reject(names, fn name ->
        Regex.match?(~r/(?<![a-z0-9_])#{name}(?![a-z0-9_])/, @reference)
      end)

    assert missing == []
  end

  test "documents parser-only syntax" do
    assert @reference =~ "count(*)"
    assert @reference =~ "INTERVAL n SECOND|MINUTE|HOUR|DAY|WEEK"
  end

  test "every SQL example parses" do
    examples = Regex.scan(~r/```sql\n(.*?)\n```/s, @reference, capture: :all_but_first)
    assert length(examples) > 3

    for [example] <- examples do
      assert [_ | _] = Guardian.AST.parse_statements(example)
    end
  end

  test "rule examples validate together and the rule reference includes every counter operator" do
    [_, rule_section] = String.split(@reference, "## Ingest rules\n", parts: 2)
    rule_section = rule_section |> String.split("## Not supported", parts: 2) |> hd()
    examples = Regex.scan(~r/```gsql\n(.*?)\n```/s, rule_section, capture: :all_but_first)
    assert length(examples) >= 2

    files =
      for {[example], n} <- Enum.with_index(examples), into: %{} do
        table = if n == 0, do: "logins", else: "reference_#{n}"
        {"#{table}/reference.gsql", example}
      end

    assert Guardian.Rules.RuleSet.validate(files).errors == []

    for {name, _arity} <- Guardian.Counters.Aggregate.operators(),
        do: assert(rule_section =~ name)
  end
end
