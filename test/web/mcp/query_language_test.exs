defmodule Web.MCP.QueryLanguageTest do
  use ExUnit.Case, async: true

  @reference File.read!("lib/web/mcp/query_language.md")

  test "documents every registered function and aggregate" do
    # `interval` is registered for the INTERVAL n UNIT syntax, but INTERVAL is a keyword,
    # so interval(...) cannot be called directly.
    names = Enum.uniq(Query.Function.names() ++ Aggregation.names()) -- ["interval"]

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
      assert [_ | _] = AST.parse_statements(example)
    end
  end
end
