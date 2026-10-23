defmodule Query.Executor do
  # Internal to Query: `Query.run/1` calls it in the query process.
  @moduledoc false

  alias Query.DistributedStream
  alias Query.Evaluation
  alias Query.Evaluation.SegmentSnapshot
  alias Query.Limits
  alias Query.Planner
  alias Query.Sorting
  alias Query.WorkerErrors
  alias Storage.Column

  @doc """
  Plans a SELECT, runs each step of the plan, and returns the rows, capped by
  `Query.Limits.cap_rows/1`. Runs in the query process, the consumer of the plan's
  DistributedStream pipeline; worker exceptions are reported to `errors`, a
  `Query.WorkerErrors` collector.
  """
  def run(statement, errors) do
    statement
    |> Planner.query_plan()
    |> Enum.reduce(nil, &step(&1, &2, errors))
    |> Limits.cap_rows()
    |> Enum.to_list()
  end

  defp step({:from, nil}, nil = _stream, _errors) do
    [%SegmentSnapshot{columns: %{}, count: 1}]
  end

  defp step({:from, %AST.Node.Identifier{name: "schema"}}, nil = _stream, _errors) do
    Query.VirtualTable.Schema.snapshots()
  end

  defp step({:from, %AST.Node.Identifier{name: table}}, nil = _stream, errors) do
    Cluster.connected_nodes()
    |> DistributedStream.fan_out(fn node ->
      {node, 0}
    end)
    |> DistributedStream.transform(fn nodes ->
      node = Node.self()
      [^node] = Enum.to_list(nodes)
      Storage.segment_ids(table)
    end)
    |> DistributedStream.flat_map(fn segment_id when is_binary(segment_id) ->
      # Guarded like evaluation, so a segment that is gone fails the query with a
      # Query.Error naming it, and no crash report.
      WorkerErrors.guard(errors, fn -> [Evaluation.snapshot!(segment_id)] end)
    end)
  end

  defp step({:select, select_exprs}, stream, errors) do
    stream
    |> DistributedStream.flat_map(fn %SegmentSnapshot{} = snapshot ->
      WorkerErrors.guard(errors, fn ->
        select_exprs
        |> Enum.map(&Evaluation.eval(snapshot, &1))
        |> Enum.map(&Column.to_list/1)
        |> transpose()
      end)
    end)
  end

  defp step({:where, _where_expr}, stream, _errors) do
    stream
    |> DistributedStream.flat_map(fn
      [true | row] -> [row]
      [_ | _row] -> []
    end)
  end

  defp step({:select_where, select_exprs, %AST.Node.Literal{value: true}}, stream, errors) do
    # Optimize a special case where the planner inserts a "WHERE true"
    # clause.
    step({:select, select_exprs}, stream, errors)
  end

  defp step({:select_where, select_exprs, where_expr}, stream, errors) do
    stream
    |> DistributedStream.flat_map(fn %SegmentSnapshot{} = snapshot ->
      WorkerErrors.guard(errors, fn -> select_where(snapshot, select_exprs, where_expr) end)
    end)
  end

  defp step({:group_by, group_by_exprs, aggregate_names_and_arities}, stream, errors) do
    {aggregate_names, arities} = Enum.unzip(aggregate_names_and_arities)
    aggregations = Enum.map(aggregate_names, &Aggregation.fetch!/1)
    num_group_by_exprs = length(group_by_exprs)

    partitions = DistributedStream.partitions(concurrency: 2)

    # TODO: directly fan_out without pulling through a stream
    stream
    |> DistributedStream.map(fn row ->
      SuperList.split(row, num_group_by_exprs)
    end)
    |> DistributedStream.fan_out(fn {key, _row} ->
      Query.Rendezvous.top(partitions, key)
    end)
    |> DistributedStream.transform(fn stream ->
      stream
      |> values_to_sketches(aggregations, arities, errors)
      |> aggregate_sketches(aggregations, errors)
      |> sketches_to_values(aggregations, errors)
    end)
  end

  defp step({:default, default_row}, stream, _errors) do
    start_func = fn ->
      false
    end

    reduce_func = fn row, _acc ->
      {[row], true}
    end

    last_func = fn
      false -> {[default_row], false}
      true -> {[], true}
    end

    after_func = fn _acc ->
      nil
    end

    Stream.transform(stream, start_func, reduce_func, last_func, after_func)
  end

  defp step({:reassemble_segments, keys_and_old_exprs}, stream, _errors) do
    DistributedStream.transform(stream, fn stream ->
      {keys, _old_exprs} = Enum.unzip(keys_and_old_exprs)

      stream
      |> Stream.chunk_every(16384)
      |> Stream.map(fn rows ->
        columns = keys |> Enum.zip(rows_to_columns(rows, keys)) |> Map.new()
        %SegmentSnapshot{columns: columns, count: length(rows)}
      end)
    end)
  end

  defp step({:order_by, directions}, stream, _errors) do
    # Sorted in memory here, so cap its input, not only the result.
    stream
    |> Limits.cap_rows()
    |> Sorting.sort(directions)
    |> Sorting.drop_prefix(directions)
  end

  defp step({:limit, limit}, stream, _errors) do
    Stream.take(stream, limit)
  end

  defp step({:order_by_limit, directions, limit}, stream, _errors) do
    Limits.check_sorted_limit!(limit)

    stream
    |> DistributedStream.fan_out()
    |> DistributedStream.transform(fn stream ->
      Sorting.sort_limit(stream, directions, limit)
    end)
    |> DistributedStream.fan_in()
    |> Limits.cap_rows()
    |> Enum.to_list()
    |> Sorting.sort_limit(directions, limit)
    |> Sorting.drop_prefix(directions)
  end

  defp select_where(%SegmentSnapshot{count: count} = snapshot, select_exprs, where_expr) do
    where_column = Evaluation.eval(snapshot, where_expr)

    case Column.true_count(where_column) do
      0 ->
        # All WHERE values were false.
        []

      ^count ->
        # All WHERE values were true.
        select_exprs
        |> Enum.map(&Evaluation.eval(snapshot, &1))
        |> Enum.map(&Column.to_list/1)
        |> transpose()

      _ ->
        select_exprs
        |> Enum.map(&Evaluation.eval(snapshot, &1))
        |> Enum.map(&Column.filter(&1, where_column))
        |> Enum.map(&Column.to_list/1)
        |> transpose()
    end
  end

  # Packs rows into one column per key. Columns have no size caps, so any valid values
  # fit. A value no column can hold (such as a list nested too deeply) raises naming
  # the column. Public for tests.
  @doc false
  def rows_to_columns(rows, keys) do
    rows
    |> transpose()
    |> Enum.zip_with(keys, fn values, key ->
      try do
        Column.from_list(values)
      rescue
        error in ArgumentError ->
          reraise ArgumentError,
                  [
                    message:
                      "query result column #{inspect(key)} holds a value no column can " <>
                        "store: #{Exception.message(error)}",
                  ],
                  __STACKTRACE__
      end
    end)
  end

  defp transpose(columns) do
    if SuperList.applicable?(columns) do
      SuperList.transpose(columns)
    else
      Enum.zip(columns)
      |> Enum.map(&Tuple.to_list/1)
    end
  end

  # The GROUP BY steps run in a DistributedStream transform, so an aggregate that
  # raises (an invalid n, say) is guarded per row like evaluation: the error is
  # reported to the query and no crash report is logged. After the first error the
  # guard returns [] without running, so the stage still reads all of its input, as
  # DistributedStream requires, without computing anything more.
  defp values_to_sketches(stream, aggregations, arities, errors) do
    Stream.flat_map(stream, fn {key, row} ->
      WorkerErrors.guard(errors, fn ->
        [{key, Aggregation.start_row(aggregations, arities, row)}]
      end)
    end)
  end

  defp aggregate_sketches(stream, aggregations, errors) do
    tab = :ets.new(nil, [:public])

    Enum.each(stream, fn {key, row} ->
      WorkerErrors.guard(errors, fn ->
        case :ets.lookup(tab, key) do
          [] ->
            true = :ets.insert(tab, {key, row})

          [{_key, old_row}] ->
            row = SuperList.map(aggregations, row, old_row, &Aggregation.merge/3)
            true = :ets.insert(tab, {key, row})
        end
      end)
    end)

    Utils.tab2stream(tab, delete_after: true)
  end

  defp sketches_to_values(stream, aggregations, errors) do
    Stream.flat_map(stream, fn {_key, row} ->
      WorkerErrors.guard(errors, fn ->
        [SuperList.map(aggregations, row, &Aggregation.finish/2)]
      end)
    end)
  end
end
