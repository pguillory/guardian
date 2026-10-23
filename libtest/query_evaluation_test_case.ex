defmodule Query.EvaluationTestCase do
  alias Query.Evaluation.SegmentSnapshot
  alias Storage.Column

  defmacro __using__(opts \\ []) do
    quote do
      import Query.EvaluationTestCase
      use ExUnit.Case, unquote(opts)
    end
  end

  def eval(source, row \\ %{}) when is_binary(source) do
    row = Map.new(row, fn {k, v} -> {to_string(k), v} end)

    [result] = Query.Evaluation.eval(snapshot([row]), source) |> Column.to_list()

    other_rows =
      for value <- [false, true, 123, 4.5, "a", [], [false], [true], [123], [4.5], ["a"]] do
        Map.new(row, fn {k, _v} -> {k, value} end)
      end

    multirow = snapshot([row, row | other_rows])
    [^result, ^result | _] = Query.Evaluation.eval(multirow, source) |> Column.to_list()

    ^result = Query.Evaluation.eval(row, source)
    ^result = Query.Evaluation.eval(row, Query.Evaluation.pre_eval(source))

    result
  end

  @doc """
  Evaluates `source` once over a segment snapshot of `rows` and once per row, and
  returns both result lists. They should be equal: segment-wide fast paths must give the
  same answer as row-by-row evaluation.
  """
  def eval_segment_and_rows(source, rows) when is_binary(source) do
    rows = Enum.map(rows, &Map.new(&1, fn {k, v} -> {to_string(k), v} end))
    segment = Query.Evaluation.eval(snapshot(rows), source) |> Column.to_list()
    per_row = Enum.map(rows, &Query.Evaluation.eval(&1, source))
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
  (`Aggregation.start_row/3`, `merge/3`, `finish/2`, and `default/1` for no rows),
  merging each row into the accumulator as GROUP BY does: merge(new, old).
  """
  def eval_aggregate(source, rows) when is_binary(source) do
    %AST.Node.AggregateFunctionCall{name: name, args: args} = AST.parse_expression(source)
    aggregation = Aggregation.fetch!(name)

    if rows == [] do
      Aggregation.default(aggregation)
    else
      rows = Enum.map(rows, &Map.new(&1, fn {k, v} -> {to_string(k), v} end))

      rows
      |> Enum.map(fn row ->
        values = Enum.map(args, &Query.Evaluation.eval(row, &1))
        [acc] = Aggregation.start_row([aggregation], [length(args)], values)
        acc
      end)
      |> Enum.reduce(&Aggregation.merge(aggregation, &1, &2))
      |> then(&Aggregation.finish(aggregation, &1))
    end
  end
end
