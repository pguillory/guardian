defmodule Guardian.Query.FunctionRegistryTest do
  use ExUnit.Case, async: true

  alias Guardian.Storage.Column

  # Every registered name, including aliases that share a module, must evaluate both
  # over a segment and over a single row. `interval` is reached only through the
  # INTERVAL n UNIT syntax, which supplies a string argument.
  test "every registered function evaluates under each of its names" do
    snapshot = Guardian.Query.EvaluationTestCase.snapshot([%{"v" => 1}])

    for {name, arity} <- Guardian.Query.Function.names_and_arities() do
      arg = if name == "interval", do: "1h", else: nil
      args = List.duplicate(%Guardian.AST.Node.Literal{value: arg}, arity)
      expr = %Guardian.AST.Node.FunctionCall{name: name, args: args}

      assert [_] = Guardian.Query.Evaluation.eval(snapshot, expr) |> Column.to_list(),
             "#{name}/#{arity} failed over a segment"

      Guardian.Query.Evaluation.eval(%{"v" => 1}, expr)
    end
  end

  test "aliases agree with their canonical functions" do
    for {alias_source, canonical_source} <- [
          {"adddate('2026-01-01 00:00:00', INTERVAL 1 DAY)",
           "date_add('2026-01-01 00:00:00', INTERVAL 1 DAY)"},
          {"subdate('2026-01-01 00:00:00', INTERVAL 1 DAY)",
           "date_sub('2026-01-01 00:00:00', INTERVAL 1 DAY)"},
        ] do
      assert eval(alias_source) == eval(canonical_source), alias_source
    end

    # Clock-based aliases are checked against clock reads taken around them, since a
    # separate read could fall on the other side of a second or day boundary.
    for {source, to_expected} <- [
          {"current_timestamp", & &1},
          {"current_date", &Guardian.Query.Function.Date.eval/1},
          {"curdate()", &Guardian.Query.Function.Date.eval/1},
        ] do
      before = to_expected.(Guardian.Timestamp.now())
      value = eval(source)
      after_ = to_expected.(Guardian.Timestamp.now())
      assert before <= value and value <= after_, source
    end
  end

  test "pre-evaluation keeps time aliases dynamic" do
    for source <- ["current_date", "current_timestamp"] do
      {:ok, expr} = Guardian.AST.parse_expression(source)
      assert Guardian.Query.Evaluation.pre_eval(expr) == expr
    end
  end

  defp eval(source) do
    {:ok, expr} = Guardian.AST.parse_expression(source)
    Guardian.Query.Evaluation.eval(%{}, expr)
  end
end
