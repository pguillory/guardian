defmodule Guardian.Rules do
  @moduledoc """
  Ingest-time rules: SET, UNSET, TRACK and LOOKUP statements, in files per table, run on each event
  sent through the ingest APIs before it is stored.

  - `lookup/1`: the compiled rules for a table (read by `Guardian.Rules.Runner`, per event).
  - `run/2`: runs a table's rules on flattened rows (`Guardian.Rules.Runner`).
  - `list_rules/1`, `read_rule/2`: read the rule store directly.
  - `write_rule/3`, `delete_rule/2`: validated, locked writes (`Guardian.Rules.Server`).
  - `reload/0`: re-reads the store on this node; writers call it on every node.

  The pieces: `Guardian.Rules.RuleSet` parses and validates a whole set, `Guardian.Rules.Compiler`
  turns a table's plan into a module, `Guardian.Rules.Runtime` is what that module calls,
  and `Guardian.Rules.Server` loads, reloads and writes, owning the rule store's
  lock policy (files are read and written through `Guardian.ObjectStore`, and the
  write lock is a `Guardian.ObjectStore.Lock`); its synchronous
  `Guardian.Rules.Publisher` owns activation, publication and the module pool. See
  `docs/architecture/system.md` ("Rules") and `lib/guardian/rules/AGENTS.md`.
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
  def published do
    :persistent_term.get(@tables_key, nil)
  end

  @doc false
  def publish(tables) do
    :persistent_term.put(@tables_key, tables)
  end

  @doc false
  def put_store(store) do
    :persistent_term.put(@store_key, store)
  end

  @doc false
  def store do
    :persistent_term.get(@store_key)
  end

  defdelegate run(table, rows), to: Guardian.Rules.Runner

  @doc false
  defdelegate run_with_metadata(table, rows), to: Guardian.Rules.Runner

  @doc "Every rule file (optionally one table's): `{:ok, [%{table, name, size}]}`."
  def list_rules(table \\ nil) do
    with {:ok, objects} <- Guardian.ObjectStore.list(store()) do
      rules =
        for %{key: key, size: size} <- objects,
            {:ok, file_table, name} <- [Guardian.Rules.RuleSet.parse_key(key)],
            table == nil or file_table == table do
          %{table: file_table, name: name, size: size}
        end

      {:ok, rules}
    end
  end

  @doc "A rule file's source: `{:ok, source}` or `{:error, message}`."
  def read_rule(table, name) do
    with :ok <- Guardian.Rules.RuleSet.check_path(table, name) do
      case Guardian.ObjectStore.get(store(), Guardian.Rules.RuleSet.key(table, name)) do
        {:ok, source, _meta} ->
          {:ok, source}

        {:error, :not_found} ->
          {:error, "no rule file #{Guardian.Rules.RuleSet.key(table, name)}"}

        {:error, message} ->
          {:error, message}
      end
    end
  end

  @doc """
  Creates or replaces a rule file. See `Guardian.Rules.Server` for the outcomes: `{:ok,
  result}` when saved, `{:error, {:rejected, messages}}`, `{:error, :busy}` when the
  write lock is held (nothing changed), or `{:error, message}`.
  """
  def write_rule(table, name, source) do
    Guardian.Rules.Server.write(table, name, source)
  end

  @doc "Deletes a rule file; outcomes as for `write_rule/3`."
  def delete_rule(table, name) do
    Guardian.Rules.Server.write(table, name, :delete)
  end

  @doc "Re-reads the store and publishes any change. Returns `:ok` or `{:error, message}`."
  def reload do
    Guardian.Rules.Server.reload()
  end
end
