defmodule Rules do
  @moduledoc """
  Ingest-time rules: SET and UNSET statements, in files per table, run on each event
  sent through the ingest APIs before it is stored.

  - `lookup/1`: the compiled rules for a table (read by `Rules.Runner`, per event).
  - `run/2`: runs a table's rules on flattened rows (`Rules.Runner`).
  - `list_rules/1`, `read_rule/2`: read the rule store directly.
  - `write_rule/3`, `delete_rule/2`: validated, locked writes (`Rules.Server`).
  - `reload/0`: re-reads the store on this node; writers call it on every node.

  The pieces: `Rules.RuleSet` parses and validates a whole set, `Rules.Compiler`
  turns a table's plan into a module, `Rules.Runtime` is what that module calls,
  `Rules.Store` reads and writes the files, `Rules.Lock` is the write lock, and
  `Rules.Server` loads, reloads, polls, writes and publishes. See
  `docs/architecture/system.md` ("Rules") and `lib/rules/CLAUDE.md`.
  """

  @tables_key {__MODULE__, :tables}
  @store_key {__MODULE__, :store}

  @doc """
  The table's compiled rules module, `{:invalid, message}` when its stored rules
  failed validation, or nil when it has none.
  """
  def lookup(table) do
    :persistent_term.get(@tables_key, %{}) |> Map.get(table)
  end

  @doc false
  def published, do: :persistent_term.get(@tables_key, nil)

  @doc false
  def publish(tables), do: :persistent_term.put(@tables_key, tables)

  @doc false
  def put_store(store), do: :persistent_term.put(@store_key, store)

  defp store, do: :persistent_term.get(@store_key)

  defdelegate run(table, rows), to: Rules.Runner

  @doc false
  defdelegate run_with_metadata(table, rows), to: Rules.Runner

  @doc "Every rule file (optionally one table's): `{:ok, [%{table, name, size}]}`."
  def list_rules(table \\ nil) do
    case Rules.Store.list(store()) do
      {:ok, objects} ->
        rules =
          for %{key: key, size: size} <- objects,
              {:ok, file_table, name} <- [Rules.RuleSet.parse_key(key)],
              table == nil or file_table == table do
            %{table: file_table, name: name, size: size}
          end

        {:ok, rules}

      {:error, reason} ->
        {:error, Rules.Store.reason_message(reason)}
    end
  end

  @doc "A rule file's source: `{:ok, source}` or `{:error, message}`."
  def read_rule(table, name) do
    with :ok <- Rules.RuleSet.check_path(table, name) do
      case Rules.Store.get(store(), Rules.RuleSet.key(table, name)) do
        {:ok, source, _meta} -> {:ok, source}
        {:error, :not_found} -> {:error, "no rule file #{Rules.RuleSet.key(table, name)}"}
        {:error, reason} -> {:error, Rules.Store.reason_message(reason)}
      end
    end
  end

  @doc """
  Creates or replaces a rule file. See `Rules.Server` for the outcomes: `{:ok,
  result}` when saved, `{:error, {:rejected, messages}}`, `{:error, {:unknown,
  message}}` when it may have been saved, or `{:error, message}`.
  """
  def write_rule(table, name, source), do: Rules.Server.write(table, name, source)

  @doc "Deletes a rule file; outcomes as for `write_rule/3`."
  def delete_rule(table, name), do: Rules.Server.write(table, name, :delete)

  @doc "Re-reads the store and publishes any change. Returns `:ok` or `{:error, message}`."
  def reload, do: Rules.Server.reload()
end
