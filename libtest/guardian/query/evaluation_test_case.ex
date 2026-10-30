defmodule Guardian.Query.EvaluationTestCase do
  alias Guardian.Query.Evaluation.SegmentSnapshot
  alias Guardian.Storage.Column

  defmacro __using__(opts \\ []) do
    quote do
      import Guardian.Query.EvaluationTestCase
      use ExUnit.Case, unquote(opts)
    end
  end

  def eval(source, row \\ %{}) when is_binary(source) do
    row = Map.new(row, fn {k, v} -> {to_string(k), v} end)

    [result] = Guardian.Query.Evaluation.eval(snapshot([row]), source) |> Column.to_list()

    other_rows =
      for value <- [false, true, 123, 4.5, "a", [], [false], [true], [123], [4.5], ["a"]] do
        Map.new(row, fn {k, _v} -> {k, value} end)
      end

    multirow = snapshot([row, row | other_rows])
    [^result, ^result | _] = Guardian.Query.Evaluation.eval(multirow, source) |> Column.to_list()

    ^result = Guardian.Query.Evaluation.eval(row, source)
    ^result = Guardian.Query.Evaluation.eval(row, Guardian.Query.Evaluation.pre_eval(source))

    result
  end

  @doc """
  Evaluates `source` once over a segment snapshot of `rows` and once per row, and
  returns both result lists. They should be equal: segment-wide fast paths must give the
  same answer as row-by-row evaluation.
  """
  def eval_segment_and_rows(source, rows) when is_binary(source) do
    rows = Enum.map(rows, &Map.new(&1, fn {k, v} -> {to_string(k), v} end))
    segment = Guardian.Query.Evaluation.eval(snapshot(rows), source) |> Column.to_list()
    per_row = Enum.map(rows, &Guardian.Query.Evaluation.eval(&1, source))
    {segment, per_row}
  end

  @doc """
  A column snapshot of `rows` (maps with string keys), evaluated like a stored segment:
  each key is a column, `nil` where a row lacks it.
  """
  def snapshot(rows) do
    keys = rows |> Enum.flat_map(&Map.keys/1) |> Enum.uniq()

    columns =
      Map.new(keys, fn key ->
        {key, rows |> Enum.map(&Map.get(&1, key)) |> Column.from_list()}
      end)

    %SegmentSnapshot{columns: columns, count: length(rows)}
  end

  @doc """
  Runs the aggregate call `source` over `rows` with the production dispatch
  (`Guardian.Aggregation.start_row/3`, `merge/3`, `finish/2`, and `default/1` for no rows),
  merging each row into the accumulator as GROUP BY does: merge(new, old).
  """
  def eval_aggregate(source, rows) when is_binary(source) do
    {:ok, %Guardian.AST.Node.AggregateFunctionCall{name: name, args: args}} =
      Guardian.AST.parse_expression(source)

    aggregation = Guardian.Aggregation.fetch!(name)

    if rows == [] do
      Guardian.Aggregation.default(aggregation)
    else
      rows = Enum.map(rows, &Map.new(&1, fn {k, v} -> {to_string(k), v} end))

      rows
      |> Enum.map(fn row ->
        values = Enum.map(args, &Guardian.Query.Evaluation.eval(row, &1))
        [acc] = Guardian.Aggregation.start_row([aggregation], [length(args)], values)
        acc
      end)
      |> Enum.reduce(&Guardian.Aggregation.merge(aggregation, &1, &2))
      |> then(&Guardian.Aggregation.finish(aggregation, &1))
    end
  end
end
