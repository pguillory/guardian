defmodule Guardian.Storage.Schema do
  # Internal to Storage; see lib/guardian/storage/CLAUDE.md, "Public boundary".
  @moduledoc false

  alias Guardian.Storage.Column.Metadata
  alias Guardian.Storage.Segment
  alias Guardian.Storage.Segment.Registration
  require Metadata
  require Registration
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def add_segment(registration, schema) do
    GenServer.call(__MODULE__, {:add_segment, registration, schema})
  end

  def get_schema(table) do
    GenServer.call(__MODULE__, {:get_schema, table})
  end

  def get_count(table) do
    GenServer.call(__MODULE__, {:get_count, table})
  end

  def get_tables do
    GenServer.call(__MODULE__, :get_tables)
  end

  # State: %{table => {schema, event_count, segment_count}} over the table's loaded
  # segments. A table is removed when its last loaded segment goes away.
  def init(_opts) do
    :ets.new(__MODULE__, [:named_table])
    state = %{}
    {:ok, state}
  end

  def handle_call({:get_schema, table}, _, state) do
    {schema, _count, _segment_count} = Map.get(state, table, {%{}, 0, 0})
    {:reply, {:ok, schema}, state}
  end

  def handle_call({:get_count, table}, _, state) do
    {_schema, count, _segment_count} = Map.get(state, table, {%{}, 0, 0})
    {:reply, {:ok, count}, state}
  end

  def handle_call(:get_tables, _, state) do
    tables = state |> Map.keys() |> Enum.sort()

    {:reply, {:ok, tables}, state}
  end

  def handle_call({:add_segment, registration, schema}, _, state) do
    Registration.tuple(segment: segment, table: table) = registration
    true = Segment.full!(segment)
    count = Segment.count!(segment)
    ref = Process.monitor(segment)
    true = :ets.insert(__MODULE__, {ref, table, schema, count})

    state =
      Map.update(state, table, {schema, count, 1}, fn {old_schema, old_count, segment_count} ->
        {merge_schemas(old_schema, schema), old_count + count, segment_count + 1}
      end)

    {:reply, :ok, state}
  end

  def handle_info({:DOWN, ref, :process, _segment, _reason}, state) do
    [{_ref, table, schema, count}] = :ets.lookup(__MODULE__, ref)
    true = :ets.delete(__MODULE__, ref)
    {old_schema, old_count, segment_count} = Map.fetch!(state, table)

    # Forget a table once its last loaded segment is gone, so expired tables stop
    # appearing in table_names/0. Otherwise drop columns no remaining segment has.
    state =
      case segment_count do
        1 ->
          Map.delete(state, table)

        _ ->
          new_schema = old_schema |> subtract_schema(schema) |> drop_empty_columns()
          Map.put(state, table, {new_schema, old_count - count, segment_count - 1})
      end

    {:noreply, state}
  end

  defp drop_empty_columns(schema) do
    schema
    |> Enum.reject(fn {_key, [Metadata.tuple(count: count) | _]} -> count == 0 end)
    |> Map.new()
  end

  def merge_schemas(schema1, schema2) do
    Map.merge(schema1, schema2, fn _key, metadata1, metadata2 ->
      Metadata.add(metadata1, metadata2)
    end)
  end

  def subtract_schema(schema1, schema2) do
    Map.merge(schema1, schema2, fn _key, metadata1, metadata2 ->
      Metadata.subtract(metadata1, metadata2)
    end)
  end
end
