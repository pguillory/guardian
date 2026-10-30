defmodule Guardian.Query.Evaluation do
  @moduledoc """
  Columnar expression evaluation for Guardian queries.

  Evaluates AST expressions on entire columns at once for performance. Supports both
  columnar evaluation (on segments) and scalar evaluation (on single events).

  ## Evaluation Modes

  ### Columnar (Segment)

  Evaluates expression on all rows in a segment simultaneously:

      iex> snapshot = Guardian.Query.Evaluation.snapshot!(segment_id) # a segment of 1000 events
      iex> Guardian.Query.Evaluation.eval(snapshot, %Guardian.AST.Node.Identifier{name: "amount"})
      %Column{data: [100, 200, nil, 150, ...]}

  ### Scalar (Event)

  Evaluates expression on a single event map:

      iex> event = %{"amount" => 100, "tax" => 10}
      iex> Guardian.Query.Evaluation.eval(event, parse("amount + tax"))
      110

  ## SegmentSnapshot

  Queries work with `SegmentSnapshot` structs that contain:

  - `segment` - A stored segment's ID, read through `Guardian.Storage.get_column/2` by
    `read_column/2`. Covers mutable and persisted segments alike.
  - `columns` - Instead of `segment`, for query temporaries: a map from key to packed
    column binary. Temporaries are plain data with no process behind them.
  - `count` - Number of events in the segment

  This abstraction allows queries to work uniformly across stored segments and query
  temporaries.

  ## Expression Evaluation Strategy

  Each evaluable AST node implements the `Guardian.Query.Eval` protocol in its own file, and
  `Guardian.Query.Eval.eval/2` returns either:

  - a packed column binary - For columnar evaluation
  - `%Constant{value: v, count: n}` - For constant values

  The dual representation enables optimizations:

  - Constants don't allocate column storage
  - Null propagation is efficient
  - Type-specific operations are optimized

  ## Constant folding (tests only)

  `pre_eval/1` folds constant subexpressions into literals (`x + (1 + 2)` becomes
  `x + 3`), leaving identifiers and non-deterministic functions (`curdate()`,
  `curtime()`, `current_date()`, `current_timestamp()`, `date()`, `now()`,
  `random()`, `generate_uuid()`) unevaluated. Queries do not use it: the planner
  evaluates expressions as written. `Guardian.Query.EvaluationTestCase` uses it to cross-check
  that folding first gives the same result.

  ## Performance

  Columnar evaluation provides:

  - Better cache locality (process contiguous data)
  - Vectorization opportunities (future NIF implementations)
  - Efficient null handling (bulk operations)
  - Reduced per-row overhead

  Future optimization: Move hot evaluation paths to NIFs for maximum performance.

  See `ARCHITECTURE.md` for query evaluation details.
  """

  alias Guardian.AST
  alias Guardian.AST.Node.Operators.ListLiteral
  alias Guardian.AST.Parser
  alias Guardian.Query.ColumnOrConstant
  alias Guardian.Query.Constant
  alias Guardian.Query.Error
  alias Guardian.Query.Eval
  alias Guardian.Query.Evaluation.SegmentSnapshot
  alias Guardian.Storage
  import ColumnOrConstant

  @non_deterministic_functions [
    {"curdate", 0},
    {"curtime", 0},
    {"current_date", 0},
    {"current_timestamp", 0},
    {"date", 0},
    {"generate_uuid", 0},
    {"now", 0},
    {"random", 0},
  ]

  def eval(expr) do
    eval(%{}, expr)
  end

  def eval(context, source) when is_binary(source) do
    {:ok, expr} = Parser.parse_expression(source)
    eval(context, expr)
  end

  def eval(%SegmentSnapshot{} = snapshot, expr) do
    expr
    |> Eval.eval(snapshot)
    |> column_or_constant_to_column()
  end

  def eval(event, expr) when is_map(event) do
    %Constant{value: value, count: 1} = Eval.eval(expr, event)
    value
  end

  @doc """
  A snapshot of a stored segment: its ID and its current row count, which bounds every
  later read of it in the query. Raises `Guardian.Query.Error` naming the segment if it no
  longer exists (deleted or expired since the query listed it) or stops during the
  read.
  """
  def snapshot!(segment_id) when is_binary(segment_id) do
    case Storage.segment_row_count(segment_id) do
      {:ok, count} -> %SegmentSnapshot{segment: segment_id, count: count}
      {:error, {:segment_unavailable, reason}} -> segment_unavailable!(segment_id, reason)
    end
  end

  @doc """
  Reads column `name` from a snapshot as a column or constant of the snapshot's row
  count: from its `columns` map for a temporary, or through `Guardian.Storage.get_column/2` for
  a stored segment. A column the snapshot does not have reads as nulls. Raises
  `Guardian.Query.Error` naming the segment if it is no longer available.
  """
  @spec read_column(%SegmentSnapshot{}, String.t()) :: binary() | %Constant{}
  def read_column(%SegmentSnapshot{columns: columns, count: count}, name)
      when is_map(columns) do
    case Map.fetch(columns, name) do
      {:ok, column} -> resize(column, count)
      :error -> Constant.duplicate(nil, count)
    end
  end

  def read_column(%SegmentSnapshot{segment: segment_id, count: count}, name)
      when is_binary(segment_id) do
    case Storage.get_column(segment_id, name) do
      {:ok, :missing} ->
        Constant.duplicate(nil, count)

      {:ok, column} ->
        resize(column, count)

      {:error, {:segment_unavailable, reason}} ->
        segment_unavailable!(segment_id, reason)
    end
  end

  # A stored segment is named only by its ID; a snapshot holding anything else (such as
  # a PID) is a bug, so fail loudly rather than read it as an event.
  def read_column(%SegmentSnapshot{} = snapshot, _name) do
    raise ArgumentError, "not a segment ID or column snapshot: #{inspect(snapshot.segment)}"
  end

  # Every column is cut or padded to the snapshot's row count, so all reads of one
  # snapshot see the same rows even if the segment gained rows since.
  defp resize(column, count) do
    column
    |> Guardian.Storage.Column.resize(count)
    |> ColumnOrConstant.column_to_column_or_constant()
  end

  # Raises the error for a segment that disappeared or failed while a query read it.
  # Only the reason's kind is named: a crash reason can carry the segment's rows.
  @spec segment_unavailable!(String.t(), term()) :: no_return()
  defp segment_unavailable!(name, reason)
       when reason in [:not_found, :normal, :shutdown, :noproc] or
              (is_tuple(reason) and elem(reason, 0) == :shutdown) do
    # A segment is stopped normally only when it is deleted, expires, or is unloaded,
    # or when its in-memory copy is retired after its file is loaded (Storage's reads
    # retry that case once on the file, so it reaches here only if the file's copy is
    # gone too). `:noproc` is a read sent to a segment already gone, nearly always for
    # one of those reasons; a crash is logged by its manager when it happens.
    raise Error,
      message:
        "segment #{name} became unavailable during the query " <>
          "(it was deleted, expired, or moved to its file)"
  end

  defp segment_unavailable!(name, reason) do
    raise Error,
      message:
        "segment #{name} became unavailable during the query (#{Guardian.Failure.exit_kind(reason)})"
  end

  def context_count(%SegmentSnapshot{count: count}) do
    count
  end

  def context_count(%{} = _event) do
    1
  end

  def pre_eval(source) when is_binary(source) do
    {:ok, expr} = AST.parse_expression(source)

    expr
    |> pre_eval()
    |> AST.unparse()
  end

  def pre_eval(expr) do
    pre = fn
      %Guardian.AST.Node.Identifier{} = expr, acc ->
        {expr, [false | acc]}

      %Guardian.AST.Node.FunctionCall{name: name, args: args} = expr, acc
      when {name, length(args)} in @non_deterministic_functions ->
        {expr, [false | acc]}

      expr, acc ->
        {expr, [true | acc]}
    end

    post = fn
      expr, [true | acc] ->
        %Constant{value: value, count: 1} = Eval.eval(expr, %{})
        expr = value_to_literal(value)
        {expr, acc}

      expr, [false, _ | acc] ->
        {expr, [false | acc]}
    end

    {expr, _} = AST.traverse(expr, [true], pre, post)
    expr
  end

  defp value_to_literal(value) do
    true = Guardian.Storage.Value.valid?(value)

    if is_list(value) do
      %ListLiteral{exprs: Enum.map(value, &value_to_literal/1)}
    else
      %Guardian.AST.Node.Literal{value: value}
    end
  end
end
