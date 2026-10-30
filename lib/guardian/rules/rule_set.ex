defmodule Guardian.Rules.RuleSet do
  @moduledoc """
  Parses and validates a whole rule set: every rule file of every table, together.

  `validate/1` takes the files as a map of store key (`<table>/<name>.gsql`) to
  source and returns, per table, either the table's `Guardian.Rules.Plan` (statements in run
  order) or its errors, plus the list of every error. Validation is pure: it reads
  nothing and has no state, so a write validates the set it would leave behind and a
  load validates what it found.

  Errors are maps with `:file` (the store key), `:line` (or nil), `:kind`, `:detail`
  and `:message`. `error_key/1` identifies an error ignoring line numbers, so a write
  that only moves lines does not make an old error new (`new_errors/2`).
  """

  @max_file_bytes 64 * 1024
  @max_files 1_000
  @max_tables 256
  @max_statements_per_table 1_000

  def max_file_bytes do
    @max_file_bytes
  end

  def max_files do
    @max_files
  end

  def max_tables do
    @max_tables
  end

  @doc "The store key of a rule file."
  def key(table, name) do
    "#{table}/#{name}.gsql"
  end

  @doc """
  Classifies a store key: `{:ok, table, name}` for a valid rule file path,
  `{:error, message}` for a `.gsql` key at an invalid path, `:ignore` for anything
  else (such as the write lock).
  """
  def parse_key(key) do
    cond do
      not String.ends_with?(key, ".gsql") ->
        :ignore

      true ->
        case String.split(String.replace_suffix(key, ".gsql", ""), "/") do
          [table, name] ->
            case check_path(table, name) do
              :ok -> {:ok, table, name}
              {:error, message} -> {:error, message}
            end

          _ ->
            {:error, "a rule file must be <table>/<name>.gsql"}
        end
    end
  end

  @doc "Checks a table and file name for a rule file: `:ok` or `{:error, message}`."
  def check_path(table, name) do
    with :ok <- check_table(table) do
      if valid_name?(name),
        do: :ok,
        else: {:error, "rule file names must match [a-z0-9_][a-z0-9_-]* and be at most 64 bytes"}
    end
  end

  @doc "Checks whether a table name is valid for rule files and counter targets."
  def check_table(table) do
    if Guardian.Engine.valid_table_name?(table),
      do: :ok,
      else: {:error, Exception.message(%Guardian.Engine.InvalidTableNameError{table: table})}
  end

  def valid_name?(name) when is_binary(name) do
    byte_size(name) <= 64 and String.match?(name, ~r/\A[a-z0-9_][a-z0-9_-]*\z/)
  end

  def valid_name?(_name) do
    false
  end

  @doc """
  Validates `files` (store key => source). Returns `%{tables: %{table => {:ok, plan}
  | {:error, errors}}, errors: errors}`. A table with any error has no plan.
  """
  def validate(files) when is_map(files) do
    files |> prepare() |> Map.take([:tables, :errors])
  end

  @doc """
  Prepares whole-set plans for validation and activation. `candidates` are locally
  valid, unbound table plans (Resolution's input); `tables` are resolved against the
  whole candidate set. Only resolved plans may compile for execution.
  """
  def prepare(files) when is_map(files) do
    keys = files |> Map.keys() |> Enum.sort()

    {parsed, errors} =
      Enum.reduce(keys, {%{}, []}, fn key, {parsed, errors} ->
        case parse_file(key, Map.fetch!(files, key)) do
          {:ok, table, statements} ->
            {Map.update(parsed, table, [{key, statements}], &(&1 ++ [{key, statements}])), errors}

          {:error, table, file_errors} ->
            parsed = if table, do: Map.put_new(parsed, table, []), else: parsed
            {parsed, errors ++ Enum.map(file_errors, &Map.put(&1, :table, table))}
        end
      end)

    set_errors = set_limit_errors(keys, parsed)

    tables =
      Map.new(parsed, fn {table, file_statements} ->
        file_errors = Enum.filter(errors ++ set_errors, &(&1.table == table))
        statements = Enum.flat_map(file_statements, fn {_key, statements} -> statements end)

        case file_errors ++ table_errors(table, statements) do
          [] -> {table, {:ok, plan(table, statements)}}
          table_errors -> {table, {:error, table_errors}}
        end
      end)

    candidates = tables
    tables = Guardian.Rules.Resolution.resolve(candidates)

    table_errors =
      Enum.flat_map(tables, fn
        {_table, {:error, table_errors}} -> table_errors
        _ -> []
      end)

    untabled = Enum.filter(errors ++ set_errors, &(&1.table == nil))
    all = Enum.uniq(untabled ++ table_errors)

    %{
      tables: tables,
      candidates: candidates,
      errors: Enum.sort_by(all, &{&1.file, &1.line || 0, &1.kind}),
    }
  end

  @doc "An error's identity ignoring its line: file, kind and detail."
  def error_key(error) do
    {error.file, error.kind, error.detail}
  end

  @doc "The errors in `after_errors` that `before_errors` did not have."
  def new_errors(before_errors, after_errors) do
    before_keys = MapSet.new(before_errors, &error_key/1)
    Enum.reject(after_errors, &(error_key(&1) in before_keys))
  end

  # Whole-set limits, reported against the file that goes past them.
  defp set_limit_errors(keys, parsed) do
    rule_keys = Enum.filter(keys, &match?({:ok, _, _}, parse_key(&1)))

    file_errors =
      rule_keys
      |> Enum.drop(@max_files)
      |> Enum.map(fn key ->
        {:ok, table, _name} = parse_key(key)
        error(key, nil, :limit, "files", "more than #{@max_files} rule files in total", table)
      end)

    table_errors =
      parsed
      |> Map.keys()
      |> Enum.sort()
      |> Enum.drop(@max_tables)
      |> Enum.map(fn table ->
        error(
          "#{table}/",
          nil,
          :limit,
          "tables",
          "more than #{@max_tables} tables have rules",
          table
        )
      end)

    file_errors ++ table_errors
  end

  defp parse_file(key, source) do
    case parse_key(key) do
      :ignore ->
        {:error, nil, []}

      {:error, message} ->
        # Attribute the error to the table the key names, if it names a valid one,
        # so a misnamed file makes that table invalid rather than drop its rules.
        table = path_table(key)
        {:error, table, [error(key, nil, :path, message, message, table)]}

      {:ok, table, _name} ->
        cond do
          source == :too_large or (is_binary(source) and byte_size(source) > @max_file_bytes) ->
            {:error, table,
             [error(key, nil, :limit, "size", "is over #{@max_file_bytes} bytes", table)]}

          not is_binary(source) or not String.valid?(source) ->
            {:error, table, [error(key, nil, :encoding, "utf8", "is not UTF-8 text", table)]}

          true ->
            parse_source(key, table, source)
        end
    end
  end

  defp path_table(key) do
    with [table | _] <- String.split(key, "/"),
         true <- Guardian.Engine.valid_table_name?(table) do
      table
    else
      _ -> nil
    end
  end

  defp parse_source(key, table, source) do
    case Guardian.AST.Parser.parse_rules(source) do
      {:ok, parsed} ->
        statements =
          parsed
          |> Enum.with_index()
          |> Enum.map(fn {{statement, line}, index} ->
            Guardian.Rules.Step.new(table, key, line, index, statement)
          end)

        case Enum.flat_map(statements, &Guardian.Rules.Validation.errors/1) do
          [] -> {:ok, table, statements}
          errors -> {:error, table, errors}
        end

      {:error, e} ->
        {:error, table, [error(key, e.row + 1, :parse, e.reason, e.reason, table)]}
    end
  rescue
    # Every node reads the same store, so a bug tripped by one stored file would crash
    # Rules.Server on every node, past its restart limit, and refuse boot. Contained
    # here, it costs that one table its rules.
    e ->
      kind = inspect(e.__struct__)
      {:error, table, [error(key, nil, :parse, kind, "could not be parsed (#{kind})", table)]}
  end

  # Conflicting definitions, too many statements, and cycles.
  defp table_errors(table, statements) do
    statements = Enum.uniq_by(statements, &{&1.kind, &1.field, &1.source})

    limit_errors =
      if length(statements) > @max_statements_per_table do
        [file | _] = statements |> Enum.drop(@max_statements_per_table) |> Enum.map(& &1.file)

        [
          error(
            file,
            nil,
            :limit,
            "statements",
            "#{table} has more than #{@max_statements_per_table} statements",
            table
          ),
        ]
      else
        []
      end

    barrier_errors =
      statements
      |> Enum.reject(&(&1.kind == :unset))
      |> Guardian.Rules.DependencyGraph.barrier_violations()
      |> Enum.map(
        &Guardian.Rules.Validation.error(
          &1,
          :counter_barrier,
          &1.field,
          "LOOKUP inputs cannot depend on TRACK outputs"
        )
      )

    limit_errors ++
      conflict_errors(table, statements) ++ cycle_errors(table, statements) ++ barrier_errors
  end

  defp conflict_errors(table, statements) do
    statements
    |> Enum.group_by(& &1.field)
    |> Enum.sort()
    |> Enum.flat_map(fn {field, [first | rest]} ->
      rest
      |> Enum.map(fn other ->
        error(
          other.file,
          other.line,
          :conflict,
          # Not the other file: deleting the first definition moves the anchor, and
          # the remaining conflicts must not look new (see new_errors/2).
          field,
          "#{field} is defined differently here and in #{first.file} line #{first.line}",
          table
        )
      end)
    end)
  end

  defp cycle_errors(table, statements) do
    case Guardian.Rules.DependencyGraph.order(Enum.reject(statements, &(&1.kind == :unset))) do
      {:ok, _ordered} ->
        []

      {:cycle, remaining} ->
        fields = remaining |> Enum.map(& &1.field) |> Enum.sort()
        first = Enum.min_by(remaining, &{&1.file, &1.index})

        [
          error(
            first.file,
            first.line,
            :cycle,
            Enum.join(fields, ", "),
            "rules read each other's fields in a cycle: #{Enum.join(fields, ", ")}",
            table
          ),
        ]
    end
  end

  defp plan(table, statements) do
    statements = Enum.uniq_by(statements, &{&1.kind, &1.field, &1.source})

    {:ok, ordered} =
      Guardian.Rules.DependencyGraph.order(Enum.reject(statements, &(&1.kind == :unset)))

    unsets = Enum.filter(statements, &(&1.kind == :unset))
    steps = ordered ++ unsets
    # File and line too: compiled modules report them when a statement fails.
    identity = Enum.map(steps, &{&1.file, &1.line, &1.source})
    hash = :crypto.hash(:sha256, :erlang.term_to_binary(identity))
    %Guardian.Rules.Plan{table: table, steps: steps, hash: Base.encode16(hash, case: :lower)}
  end

  defp error(file, line, kind, detail, message, table) do
    Guardian.Rules.Validation.error(file, line, kind, detail, message, table)
  end
end
