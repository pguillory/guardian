defmodule Guardian.Query.TotalityTest do
  # Every function and operator is total: on any input it returns a storable value or
  # null, never raising, a bignum, or a non-finite float (Guardian.Query.Numeric). Each case is
  # evaluated three ways: per event (all constants), a column against constants, and
  # over multi-row columns (so the column NIFs run). The three must agree.
  use ExUnit.Case, async: true

  alias Guardian.AST.Node.Identifier
  alias Guardian.AST.Node.Literal
  alias Guardian.Storage.Column

  import Guardian.Query.Numeric, only: [int64?: 1]

  @max Guardian.Query.Numeric.max_int()
  @min Guardian.Query.Numeric.min_int()

  @values [
    nil,
    true,
    0,
    0.0,
    -1,
    -0.5,
    @max,
    @min,
    1.0e308,
    -1.0e308,
    1.0e-308,
    9.223372036854775807e18,
    -9.223372036854775808e18,
    "2026-01-01 00:00:00",
    "0000-01-01 00:00:00",
    "9999-12-31 23:59:59",
    "9999-12-31T23:59:59-01:00",
    "2026-01-01T00:00:00+02:00",
    "2026-13-01 25:00:00",
    "9223372036854775807s",
    "9223372036854775807w",
    "http://example.com:99999999999999999999/",
    "a",
    <<0xFF, 0xFE>>,
    # Past the string cap, ending in a character the cap can split.
    String.duplicate("a", Guardian.Query.Text.max_bytes() - 1) <> "é",
    [1, nil, "a"],
    [[1]],
  ]

  # Results depend on the clock or a random source, so the three ways can't agree.
  @nondeterministic ~w[curdate/0 current_date/0 current_timestamp/0 date/0 generate_uuid/0
                       now/0 random/0]

  # Functions that can return an input string, or part of one, uncut (lpad and rpad
  # when no padding is needed).
  @passthrough ~w[to_string/1 substr/2 substr/3 trim/1 ltrim/1 rtrim/1 reverse/1 if/2 if/3
                  coalesce/1 coalesce/2 coalesce/3 coalesce/4 lpad/2 rpad/2 url_path/1] ++
                 ["CASE WHEN a THEN b ELSE a END"]

  @operators [
    "a + b",
    "a - b",
    "a * b",
    "a / b",
    "-a",
    "a || b",
    "a = b",
    "a != b",
    "a < b",
    "a <= b",
    "a > b",
    "a >= b",
    "a <=> b",
    "a AND b",
    "a OR b",
    "NOT a",
    "a IS NULL",
    "a IS NOT NULL",
    "a BETWEEN b AND a",
    "a IN (b)",
    "a LIKE '%a_' OR b",
    "a NOT LIKE '%a_' OR b",
    "a ILIKE '%A_' OR b",
    "a NOT ILIKE '%A_' OR b",
    "a RLIKE '^a+' OR b",
    "a NOT RLIKE '^a+' OR b",
    "[a, b]",
    "a + INTERVAL 1 DAY",
    "CASE WHEN a THEN b ELSE a END",
  ]

  test "every operator is total on every pair of edge values" do
    for source <- @operators do
      expr = Guardian.AST.parse_expression(source)
      check(source, expr, ["a", "b"], deterministic: true)
    end
    |> report()
  end

  test "every function is total on every pair of edge values" do
    for {name, arity} <- Guardian.Query.Function.names_and_arities(), name != "test_raise" do
      # Higher arities take the pair's two values in turn rather than every combination.
      names = Enum.map(0..(arity - 1)//1, &if(rem(&1, 2) == 0, do: "a", else: "b"))
      args = Enum.map(names, &%Identifier{name: &1})
      expr = %Guardian.AST.Node.FunctionCall{name: name, args: args}

      check("#{name}/#{arity}", expr, names,
        deterministic: "#{name}/#{arity}" not in @nondeterministic
      )
    end
    |> report()
  end

  defp report(failures) do
    failures = drain_raised() ++ List.flatten(failures)
    assert failures == [], Enum.join(Enum.take(failures, 100_000), "\n")
  end

  defp check(label, expr, names, deterministic: deterministic?) do
    pairs = for a <- @values, b <- @values, do: %{"a" => a, "b" => b}
    pairs = if "b" in names, do: pairs, else: Enum.uniq_by(pairs, & &1["a"])

    # Over columns: every pair at once.
    columns = eval_snapshot(label, expr, pairs)

    for {row, column_result} <- Enum.zip(pairs, columns) do
      context = "#{label} with #{brief(row)}"

      per_event =
        eval_or_flunk(context, :raised, fn -> Guardian.Query.Evaluation.eval(row, expr) end)

      # A column of every value against `b` as a constant.
      against_constant =
        if "b" in names do
          column_rows = Enum.map(@values, &%{"a" => &1})
          index = Enum.find_index(@values, &(&1 === row["a"]))
          constant_expr = substitute(expr, "b", row["b"])
          Enum.at(eval_snapshot(context, constant_expr, column_rows), index)
        else
          per_event
        end

      results = [per_event, column_result, against_constant]

      # A built string is within the cap. Only a function that returns an input, or
      # part of one, can give more (@passthrough).
      max_string =
        if label in @passthrough,
          do: row |> Map.values() |> Enum.filter(&is_binary/1) |> Enum.map(&byte_size/1),
          else: []

      max_string = Enum.max([Guardian.Query.Text.max_bytes() | max_string])

      unstorable =
        for result <- results,
            result != :raised,
            not storable?(result) or (is_binary(result) and byte_size(result) > max_string),
            do: "#{context} gave #{brief(result)}"

      disagreements =
        cond do
          not deterministic? or :raised in results ->
            []

          not same?(per_event, column_result) ->
            [
              "#{context}: per event #{brief(per_event)}, over columns #{brief(column_result)}",
            ]

          # replace/3 reads its pattern only from a literal: a constant `b` is a
          # different query from a column `b`.
          label != "replace/3" and not same?(per_event, against_constant) ->
            [
              "#{context}: per event #{brief(per_event)}, " <>
                "against a constant #{brief(against_constant)}",
            ]

          true ->
            []
        end

      unstorable ++ disagreements
    end
  end

  defp eval_snapshot(context, expr, rows) do
    snapshot = Guardian.Query.EvaluationTestCase.snapshot(rows)

    eval_or_flunk(context, List.duplicate(:raised, length(rows)), fn ->
      snapshot |> Guardian.Query.Evaluation.eval(expr) |> Column.to_list()
    end)
  end

  defp drain_raised do
    receive do
      {:raised, message} -> [message | drain_raised()]
    after
      0 -> []
    end
  end

  # A raise is reported (drain_raised/0) and gives `raised`, a value no evaluation
  # returns, so a nil or false result is still compared.
  defp eval_or_flunk(context, raised, fun) do
    fun.()
  rescue
    exception ->
      message = exception |> Exception.message() |> String.split("\n") |> hd()
      send(self(), {:raised, "#{context} raised #{message}"})
      raised
  end

  defp substitute(%Identifier{name: name}, name, value) do
    %Literal{value: value}
  end

  defp substitute(%_{} = node, name, value) do
    node
    |> Map.from_struct()
    |> Enum.reduce(node, fn {key, field}, node ->
      Map.put(node, key, substitute(field, name, value))
    end)
  end

  defp substitute(list, name, value) when is_list(list) do
    Enum.map(list, &substitute(&1, name, value))
  end

  defp substitute(other, _name, _value) do
    other
  end

  defp storable?(value) when is_integer(value) do
    int64?(value)
  end

  defp storable?(value) do
    Guardian.Storage.Value.valid?(value)
  end

  defp brief(term) do
    inspect(term, limit: 5, printable_limit: 40)
  end

  # Equal and the same type, so 1 and 1.0 differ (0.0 and -0.0 don't).
  defp same?(a, b) when is_float(a) and is_float(b) do
    a == b
  end

  defp same?(a, b) when is_list(a) and is_list(b) do
    length(a) == length(b) and Enum.all?(Enum.zip(a, b), fn {x, y} -> same?(x, y) end)
  end

  defp same?(a, b) do
    a === b
  end
end
