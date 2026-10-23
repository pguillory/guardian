defmodule Engine do
  @moduledoc """
  High-level event ingestion interface for Guardian.

  Guardian is schemaless. Engine validates that values are storage-safe and appends
  events to the custom Storage layer. Schemas are inferred from stored events.

  ## Event Ingestion Flow

      Engine.ingest_event(table, event)
        ↓
      1. Validate storage-safe values
      2. Store in a segment
      3. Return the stored event

  - `ingest_event/2` - Insert a single event
  - `ingest_events/2` - Insert events independently, returning ordered outcomes
  - `log_event/2`, `try_log_event/2` - Write Guardian's own events (built-in tables)
  - `failure_kind/3` - Name a caught failure by kind only, for log lines

  ## Validation

  Events are validated for storage safety:

  - Invalid values (e.g., out-of-range integers, lists nested too deeply, strings or
    lists over 2^31 - 1 bytes or elements) are dropped, including values nested
    inside objects
  - Fields whose flattened dot-notation key exceeds 250 bytes are dropped
  - All keys are converted to strings, and the stored event is returned
  - No type enforcement - columns can contain mixed types

  Table names must be addressable as SQL identifiers of at most 64 bytes:
  `[a-z_][a-z0-9_]*`, excluding
  SQL keywords, `null`/`true`/`false`, `current_date`/`current_timestamp`, and the
  virtual `schema` table. This also keeps them safe in segment filenames. Other names
  raise `Engine.InvalidTableNameError` before anything is written.

  See `ARCHITECTURE.md` for architecture details.
  """

  alias Storage.Flattening
  alias Storage.Value
  require Logger

  @doc """
  Ingests each event independently and returns one ordered outcome per input.
  Invalid tables raise before any event is processed. An individual failure does
  not stop later events; failures after storage starts may have stored the event.
  """
  @spec ingest_events(String.t(), list()) :: [{:ok, map()} | {:error, String.t()}]
  def ingest_events(table, events) do
    validate_table!(table)
    Enum.map(events, &ingest_result(table, &1))
  end

  def ingest_event(table, event) do
    validate_table!(table)
    {event, flat_row} = validate_event(table, event)
    :ok = Storage.append_flattened(table, flat_row)
    event
  end

  @doc """
  Writes one of Guardian's own events (the built-in tables): stringifies `event`'s
  keys and ingests it into `table` with `ingest_event/2`. Raises if that fails.
  """
  def log_event(table, event) do
    event = Map.new(event, fn {key, value} -> {to_string(key), value} end)
    ingest_event(table, event)
  end

  @doc """
  Like `log_event/2`, but returns a failure (Storage restarting, a value that cannot be
  stored) as `{:error, kind}` instead of raising, for callers to whom the event is
  incidental. `kind` names only the failure's kind (an exception module, or an exit's
  reason kind), never the event or a message, so it is safe to log. Logs nothing
  itself: each caller decides how often to report.
  """
  @spec try_log_event(String.t(), Enumerable.t()) :: {:ok, map()} | {:error, String.t()}
  def try_log_event(table, event) do
    {:ok, log_event(table, event)}
  catch
    kind, reason -> {:error, failure_kind(kind, reason, __STACKTRACE__)}
  end

  @doc """
  Names a caught failure by its kind only, the way `try_log_event/2` reports one: the
  exception module for an error, `"exit "` and the exit's reason kind for an exit
  (`Storage.exit_kind/1`), or `"throw"`. Never the reason's contents or a message, so
  it is safe to log. Shared by the writers of built-in tables that catch their own
  failures.
  """
  @spec failure_kind(:error | :exit | :throw, term(), Exception.stacktrace()) :: String.t()
  def failure_kind(:error, reason, stacktrace) do
    %module{} = Exception.normalize(:error, reason, stacktrace)
    inspect(module)
  end

  def failure_kind(:exit, reason, _stacktrace), do: "exit " <> Storage.exit_kind(reason)
  def failure_kind(:throw, _value, _stacktrace), do: "throw"

  defp ingest_result(table, event) when is_map(event) do
    case prepare_event(table, event) do
      {:ok, event, flat_row} -> store_event(table, event, flat_row)
      {:error, _message} = error -> error
    end
  end

  defp ingest_result(_table, _event), do: {:error, "event is not a JSON object"}

  defp prepare_event(table, event) do
    {event, flat_row} = validate_event(table, event)
    {:ok, event, flat_row}
  catch
    kind, reason ->
      log_ingest_failure(table, kind, reason, __STACKTRACE__)
      {:error, "internal error before storage; the event was not stored"}
  end

  defp store_event(table, event, flat_row) do
    case Storage.append_flattened_result(table, flat_row) do
      :ok -> {:ok, event}
      {:error, :invalid_value} -> {:error, "value cannot be stored; the event was not stored"}
    end
  catch
    kind, reason ->
      log_ingest_failure(table, kind, reason, __STACKTRACE__)
      {:error, "internal error; the event may have been stored"}
  end

  defp log_ingest_failure(table, kind, reason, stack) do
    Logger.error("Event ingestion failed for #{table}: " <> Exception.format(kind, reason, stack))
  end

  # Identifiers that SQL cannot use as a plain table reference: tokenizer keywords and
  # literals, parser-level functions, and the virtual schema table.
  @reserved_table_names Enum.map(AST.Tokenizer.keywords(), &String.downcase/1) ++
                          ~w[null true false current_date current_timestamp schema]

  # Segment files are named `{table}.{32-character id}.seg`, written through a
  # `.{n}.tmp` temporary name, and filesystems cap a name at 255 bytes, so a name over
  # about 190 bytes could never be persisted. 64 leaves ample room.
  @max_table_name_bytes 64

  def max_table_name_bytes, do: @max_table_name_bytes

  @doc """
  Returns true when `table` can be addressed by SQL and is safe to use in a segment
  filename: at most #{@max_table_name_bytes} bytes.
  """
  def valid_table_name?(table) when is_binary(table) do
    byte_size(table) <= @max_table_name_bytes and
      String.match?(table, ~r/\A[a-z_][a-z0-9_]*\z/) and table not in @reserved_table_names
  end

  def valid_table_name?(_table), do: false

  defp validate_table!(table) do
    unless valid_table_name?(table) do
      raise Engine.InvalidTableNameError, table: table
    end
  end

  # Storage flattens nested objects into dot-notation columns, so validate the
  # flattened values: a nested value can be invalid even when its top-level map is
  # fine. Returns the event to report back and the validated flat row to store.
  #
  # Invalid values and over-long flattened keys are dropped individually. The flat
  # row goes to Storage as is, because unflattening cannot rebuild every shape that
  # flattening accepts, such as arrays that mix scalars and objects.
  defp validate_event(_table, event) when is_map(event) do
    flat_row = Flattening.flatten_event(event)

    {valid_row, invalid_row} =
      Map.split_with(flat_row, fn {key, value} ->
        Value.valid_key?(key) and Value.valid?(value)
      end)

    {reported_event(event, valid_row, invalid_row), valid_row}
  end

  # The reported event should hold every stored column. Candidates, in order: the
  # original with string keys (only when nothing was dropped), then the event rebuilt
  # from the stored row. Unflattening may raise on shapes it cannot represent or,
  # depending on key order, silently overwrite a field, so each candidate is checked.
  # Values may differ from the stored row only by nil padding in lists of objects.
  # If neither holds every column, fall back to the original minus every top-level
  # field that lost a value, which is best effort for such shapes.
  defp reported_event(event, valid_row, invalid_row) do
    event = stringify_keys(event)

    candidates = [
      fn -> if invalid_row == %{}, do: event end,
      fn -> rebuild(valid_row) end,
    ]

    Enum.find_value(candidates, fn candidate ->
      reported = candidate.()
      if reported != nil and all_columns_kept?(reported, valid_row), do: reported
    end) || drop_fields(event, invalid_row)
  end

  defp rebuild(row) do
    Flattening.unflatten_event(row)
  rescue
    FunctionClauseError -> nil
  end

  defp drop_fields(event, invalid_row) do
    dropped_fields =
      MapSet.new(invalid_row, fn {key, _value} ->
        [[field | _] | _] = Flattening.decode_path(key)
        field
      end)

    Map.reject(event, fn {field, _value} -> field in dropped_fields end)
  end

  defp all_columns_kept?(event, row) do
    event_row = Flattening.flatten_event(event)
    Enum.all?(Map.keys(row), &Map.has_key?(event_row, &1))
  end

  # Converts keys to strings, merging nested objects whose keys collide once
  # converted, such as :x and "x".
  defp stringify_keys(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      value = stringify_keys(value)
      Map.update(acc, to_string(key), value, &merge_values(&1, value))
    end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp merge_values(%{} = map1, %{} = map2),
    do: Map.merge(map1, map2, fn _key, v1, v2 -> merge_values(v1, v2) end)

  defp merge_values(_value1, value2), do: value2
end
