defmodule Storage.Segment.Registration do
  # Internal to Storage; see lib/storage/CLAUDE.md, "Public boundary".
  @moduledoc false

  alias Storage.Segment

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

  def segment_id(tuple(segment_id: segment_id)), do: segment_id
  def segment(tuple(segment: segment)), do: segment
  def table(tuple(table: table)), do: table

  # A manager's registry is its named ETS table of `tuple/1` registrations, keyed by
  # segment ID. The functions below are the registry operations every manager shares;
  # each manager wraps the ones it needs, so its lifecycle still reads top to bottom.
  # The functions that change a registry must run in the manager that owns it.

  @doc """
  The IDs of the segments registered in `registry` for the event table `table`.
  """
  def segment_ids(registry, table) do
    :ets.select(registry, match_spec(table: table, select: :segment_id))
  end

  @doc """
  The IDs of every segment registered in `registry`.
  """
  def all_segment_ids(registry) do
    :ets.select(registry, match_spec(select: :segment_id))
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

  @doc """
  Retires every registration in `registry` (see `retire/2`), as a manager's
  `terminate/2` does.
  """
  def retire_all(registry) do
    :ets.tab2list(registry)
    |> Enum.each(&retire(registry, &1))
  end

  @doc """
  Removes a registration from a manager's registry and stops its segment, returning
  once the process is gone.
  """
  def retire(registry, registration) do
    true = :ets.delete_object(registry, registration)
    :ok = Segment.retire(segment(registration))
  end

  @doc """
  Removes the registrations holding `segment` from a manager's registry and returns them,
  for the manager's `{:EXIT, segment, reason}` handler. Matching by PID, never by ID,
  means a late EXIT from a segment the manager no longer holds (handed off, retired,
  or replaced by a reload of the same ID) removes nothing.
  """
  def unregister_exited(registry, segment) when is_pid(segment) do
    :ets.select(registry, match_spec(segment: segment))
    |> Enum.map(fn registration ->
      true = :ets.delete_object(registry, registration)
      registration
    end)
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
