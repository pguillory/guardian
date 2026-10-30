defmodule Guardian.Engine do
  @moduledoc """
  High-level event ingestion interface for Guardian.

  Guardian is schemaless. Engine validates that values are storage-safe and appends
  events to the custom Storage layer. Schemas are inferred from stored events.

  ## Event Ingestion Flow

      Guardian.Engine.ingest_event(table, event)
        ↓
      1. Validate storage-safe values
      2. Store in a segment
      3. Return the stored row

  - `ingest_event/2` - Insert a single event
  - `ingest_events/2` - Insert events independently, returning ordered outcomes
  - `log_event/2`, `try_log_event/2` - Write Guardian's own events (built-in tables)

  ## Validation

  Events are validated for storage safety:

  - Invalid values (e.g., out-of-range integers, lists nested too deeply, strings or
    lists over 2^31 - 1 bytes or elements) are dropped, including values nested
    inside objects
  - Fields whose flattened dot-notation key exceeds 250 bytes are dropped
  - Nested objects become dot-notation columns, and the stored flat row is
    returned: exactly the columns stored, never rebuilt into nested JSON
  - No type enforcement - columns can contain mixed types

  Table names must be addressable as SQL identifiers of at most 64 bytes:
  `[a-z_][a-z0-9_]*`, excluding
  SQL keywords, `null`/`true`/`false`, `current_date`/`current_timestamp`, and the
  virtual `schema` table. This also keeps them safe in segment filenames. Other names
  raise `Guardian.Engine.InvalidTableNameError` before anything is written.

  See `ARCHITECTURE.md` for architecture details.
  """

  alias Guardian.Storage.Flattening
  alias Guardian.Storage.Value
  require Logger

  @doc """
  Ingests each event independently and returns one ordered outcome per input:
  `{:ok, row}` with the stored flat row (after the table's rules), or
  `{:error, message}`. Invalid tables raise before any event is processed. An
  individual failure does not stop later events; failures after storage starts may
  have stored the event.
  """
  @spec ingest_events(String.t(), list()) :: [{:ok, map()} | {:error, String.t()}]
  def ingest_events(table, events) do
    validate_table!(table)

    case Guardian.Rules.lookup(table) do
      nil -> Enum.map(events, &ingest_result(table, &1))
      _rules -> ingest_with_rules(table, events)
    end
  end

  @doc """
  Validates and stores one event without rules, returning the stored flat row
  (dot-notation column names, the invalid values dropped). Raises on failure.
  """
  def ingest_event(table, event) do
    validate_table!(table)
    row = validate_event(event)
    :ok = Guardian.Storage.append_flattened(table, row)
    row
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
    kind, reason -> {:error, Guardian.Failure.kind(kind, reason, __STACKTRACE__)}
  end

  defp ingest_result(table, event) when is_map(event) do
    with {:ok, row} <- prepare_event(table, event) do
      store_row(table, row)
    end
  end

  defp ingest_result(_table, _event) do
    {:error, "event is not a JSON object"}
  end

  # Rules run on every event's validated row, in a worker (Guardian.Rules.Runner), after which
  # the row they produced is validated the same way and stored. The stored row is the
  # result.
  defp ingest_with_rules(table, events) do
    prepared =
      Enum.map(events, fn event ->
        arrival = Guardian.Counters.Arrival.now()

        prepared =
          if is_map(event),
            do: prepare_event(table, event),
            else: {:error, "event is not a JSON object"}

        {prepared, arrival}
      end)

    rows = for {{:ok, row}, arrival} <- prepared, do: {row, arrival}

    case run_rules(table, rows) do
      {:ok, results} ->
        {outcomes, []} =
          Enum.map_reduce(prepared, results, fn
            {{:ok, _row}, _arrival}, [result | results] ->
              {finish_with_rules(table, result), results}

            {error, _arrival}, results ->
              {error, results}
          end)

        outcomes

      :error ->
        Enum.map(prepared, fn
          {{:ok, _row}, _arrival} ->
            {:error, "internal error before storage; the event was not stored"}

          {error, _arrival} ->
            error
        end)
    end
  end

  defp run_rules(table, rows) do
    {:ok, Guardian.Rules.run_with_metadata(table, rows)}
  catch
    kind, reason ->
      log_ingest_failure(table, kind, reason, __STACKTRACE__)
      :error
  end

  defp finish_with_rules(_table, {:error, _} = error) do
    error
  end

  # The values the rules produced are validated like the sender's.
  defp finish_with_rules(table, {:ok, row}) do
    with {:ok, row} <- before_storage(table, fn -> drop_invalid(row) end) do
      store_row(table, row)
    end
  end

  defp prepare_event(table, event) do
    before_storage(table, fn -> validate_event(event) end)
  end

  defp before_storage(table, fun) do
    {:ok, fun.()}
  catch
    kind, reason ->
      log_ingest_failure(table, kind, reason, __STACKTRACE__)
      {:error, "internal error before storage; the event was not stored"}
  end

  defp store_row(table, row) do
    case Guardian.Storage.append_flattened_result(table, row) do
      :ok -> {:ok, row}
      {:error, :invalid_value} -> {:error, "value cannot be stored; the event was not stored"}
    end
  catch
    kind, reason ->
      log_ingest_failure(table, kind, reason, __STACKTRACE__)
      {:error, "internal error; the event may have been stored"}
  end

  # The failure's kind and where it happened, never its message or the arguments in
  # the stack trace: both can carry event values.
  defp log_ingest_failure(table, kind, reason, stack) do
    Logger.error(
      "Event ingestion failed for #{table}: #{Guardian.Failure.kind(kind, reason, stack)}\n" <>
        Exception.format_stacktrace(Guardian.Failure.stacktrace(stack))
    )
  end

  # Identifiers that SQL cannot use as a plain table reference: tokenizer keywords and
  # literals, parser-level functions, and the virtual schema table.
  @reserved_table_names Enum.map(Guardian.AST.Tokenizer.keywords(), &String.downcase/1) ++
                          ~w[null true false current_date current_timestamp schema]

  # Segment files are named `{table}.{32-character id}.seg`, written through a
  # `.{n}.tmp` temporary name, and filesystems cap a name at 255 bytes, so a name over
  # about 190 bytes could never be persisted. 64 leaves ample room.
  @max_table_name_bytes 64

  def max_table_name_bytes do
    @max_table_name_bytes
  end

  @doc """
  Returns true when `table` can be addressed by SQL and is safe to use in a segment
  filename: at most #{@max_table_name_bytes} bytes.
  """
  def valid_table_name?(table) when is_binary(table) do
    byte_size(table) <= @max_table_name_bytes and
      String.match?(table, ~r/\A[a-z_][a-z0-9_]*\z/) and table not in @reserved_table_names
  end

  def valid_table_name?(_table) do
    false
  end

  defp validate_table!(table) do
    unless valid_table_name?(table) do
      raise Guardian.Engine.InvalidTableNameError, table: table
    end
  end

  # Storage flattens nested objects into dot-notation columns, so validate the
  # flattened values: a nested value can be invalid even when its top-level map is
  # fine. Invalid values and over-long flattened keys are dropped individually, and
  # the flat row that remains is both what is stored and what the caller gets back.
  defp validate_event(event) when is_map(event) do
    event |> Flattening.flatten_event() |> drop_invalid()
  end

  defp drop_invalid(flat_row) do
    Map.filter(flat_row, fn {key, value} ->
      Value.valid_key?(key) and Value.valid?(value)
    end)
  end
end
