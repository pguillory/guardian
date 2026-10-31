defmodule Guardian.Storage.Segment.Registration do
  # Internal to Storage; see lib/guardian/storage/AGENTS.md, "Public boundary".
  @moduledoc false

  alias Guardian.Storage.Segment

  defmacro tuple(opts \\ []) do
    underscore =
      quote do
        _
      end

    {segment_id, opts} = Keyword.pop_first(opts, :segment_id, underscore)
    {segment, opts} = Keyword.pop_first(opts, :segment, underscore)
    {table, opts} = Keyword.pop_first(opts, :table, underscore)
    [] = opts

    quote do
      {unquote(segment_id), unquote(segment), unquote(table)}
    end
  end

  def segment_id(tuple(segment_id: segment_id)) do
    segment_id
  end

  def segment(tuple(segment: segment)) do
    segment
  end

  def table(tuple(table: table)) do
    table
  end

  # A registry (MutableSegments, ReadableSegments) is a named ETS table of `tuple/1`
  # registrations, keyed by segment ID. The functions below are its operations; each
  # registry wraps the ones it needs. The functions that change a registry must run in
  # the process that owns it.

  @doc """
  The IDs of the segments registered in `registry` for the event table `table`.
  """
  def segment_ids(registry, table) do
    :ets.select(registry, match_spec(table: table, select: :segment_id))
  end

  @doc """
  The segment registered in `registry` under `segment_id`.
  """
  def lookup(registry, segment_id) do
    case :ets.lookup(registry, segment_id) do
      [tuple(segment: segment)] -> {:ok, segment}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Retires every registration in `registry` with `segment_id` (see `retire/2`).
  """
  def retire_segment_id(registry, segment_id) do
    :ets.select(registry, match_spec(segment_id: segment_id))
    |> Enum.each(&retire(registry, &1))
  end

  # Removes a registration from a registry and stops its segment, returning
  # once the process is gone.
  defp retire(registry, registration) do
    true = :ets.delete_object(registry, registration)
    :ok = Segment.retire(segment(registration))
  end

  @doc """
  Registers a segment in `registry` and monitors it, so the registry's `:DOWN` handler
  can `unregister/2` it.
  """
  def register(registry, tuple(segment: segment) = registration) do
    true = :ets.insert(registry, registration)
    _ref = Process.monitor(segment)
    :ok
  end

  @doc """
  Removes the registrations holding `segment` from a registry, for its `:DOWN` handler.
  Matching by PID, never by ID, means a late DOWN from a segment the registry no longer
  holds (persisting, or deleted) removes nothing.
  """
  def unregister(registry, segment) when is_pid(segment) do
    true = :ets.match_delete(registry, {:_, segment, :_})
    :ok
  end

  @segment_id :"$1"
  @segment :"$2"
  @table :"$3"

  def match_spec(opts \\ []) do
    head = {@segment_id, @segment, @table}
    conditions = []
    body = [:"$_"]

    [
      Enum.reduce(opts, {head, conditions, body}, fn
        {:segment_id, segment_id}, {head, conditions, body} ->
          head = put_elem(head, 0, segment_id)
          {head, conditions, body}

        {:segment, segment}, {head, conditions, body} ->
          head = put_elem(head, 1, segment)
          {head, conditions, body}

        {:table, table}, {head, conditions, body} ->
          head = put_elem(head, 2, table)
          {head, conditions, body}

        {:select, :segment_id}, {head, conditions, _body} ->
          body = [@segment_id]
          {head, conditions, body}

        {:select, :segment}, {head, conditions, _body} ->
          body = [@segment]
          {head, conditions, body}

        {:select, :table}, {head, conditions, _body} ->
          body = [@table]
          {head, conditions, body}
      end),
    ]
  end
end
