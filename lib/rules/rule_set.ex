defmodule Rules.RuleSet do
  @moduledoc """
  Parses and validates a whole rule set: every rule file of every table, together.

  `validate/1` takes the files as a map of store key (`<table>/<name>.gsql`) to
  source and returns, per table, either the table's `Rules.Plan` (statements in run
  order) or its errors, plus the list of every error. Validation is pure: it reads
  nothing and has no state, so a write validates the set it would leave behind and a
  load validates what it found.

  Errors are maps with `:file` (the store key), `:line` (or nil), `:kind`, `:detail`
  and `:message`. `error_key/1` identifies an error ignoring line numbers, so a write
  that only moves lines does not make an old error new (`new_errors/2`).
  """

  alias AST.Node.Statements.SetStatement
  alias AST.Node.Statements.UnsetStatement

  @max_file_bytes 64 * 1024
  @max_files 1_000
  @max_tables 256
  @max_statements_per_table 1_000

  # Guardian's own tables. Rules run only on events sent through the ingest APIs, so
  # rules for these would never run.
  @builtin_tables ~w[system_stats web_requests web_responses query_parse_errors queries]

  def max_file_bytes, do: @max_file_bytes
  def max_files, do: @max_files
  def max_tables, do: @max_tables
  def builtin_tables, do: @builtin_tables

  @doc "The store key of a rule file."
  def key(table, name), do: "#{table}/#{name}.gsql"

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
    cond do
      not Engine.valid_table_name?(table) ->
        {:error, Exception.message(%Engine.InvalidTableNameError{table: table})}

      table in @builtin_tables ->
        {:error, "#{table} is a built-in table; rules run only on ingested events"}

      not valid_name?(name) ->
        {:error, "rule file names must match [a-z0-9_][a-z0-9_-]* and be at most 64 bytes"}

      true ->
        :ok
    end
  end

  def valid_name?(name) when is_binary(name) do
    byte_size(name) <= 64 and String.match?(name, ~r/\A[a-z0-9_][a-z0-9_-]*\z/)
  end

  def valid_name?(_name), do: false

  @doc """
  Validates `files` (store key => source). Returns `%{tables: %{table => {:ok, plan}
  | {:error, errors}}, errors: errors}`. A table with any error has no plan.
  """
  def validate(files) when is_map(files) do
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

    table_errors =
      Enum.flat_map(tables, fn
        {_table, {:error, table_errors}} -> table_errors
        _ -> []
      end)

    untabled = Enum.filter(errors ++ set_errors, &(&1.table == nil))
    all = Enum.uniq(untabled ++ table_errors)
    %{tables: tables, errors: Enum.sort_by(all, &{&1.file, &1.line || 0, &1.kind})}
  end

  @doc "An error's identity ignoring its line: file, kind and detail."
  def error_key(error), do: {error.file, error.kind, error.detail}

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
         true <- Engine.valid_table_name?(table) and table not in @builtin_tables do
      table
    else
      _ -> nil
    end
  end

  defp parse_source(key, table, source) do
    statements =
      source
      |> AST.Parser.parse_rules()
      |> Enum.with_index()
      |> Enum.map(fn {{statement, line}, index} ->
        statement(table, key, line, index, statement)
      end)

    case Enum.flat_map(statements, &expression_errors/1) do
      [] -> {:ok, table, statements}
      errors -> {:error, table, errors}
    end
  rescue
    e in AST.ParseError ->
      {:error, table, [error(key, e.row + 1, :parse, e.reason, e.reason, table)]}

    # A stored file must never crash the server that loads it: report anything else
    # as a parse error, by kind only.
    e ->
      kind = inspect(e.__struct__)
      {:error, table, [error(key, nil, :parse, kind, "could not be parsed (#{kind})", table)]}
  end

  defp statement(table, key, line, index, %SetStatement{} = statement) do
    %{
      table: table,
      file: key,
      line: line,
      index: index,
      kind: :set,
      field: statement.field.name,
      value_expr: statement.value_expr,
      where_expr: statement.where_expr,
      reads: reads([statement.value_expr, statement.where_expr]),
      source: AST.unparse(statement),
    }
  end

  defp statement(table, key, line, index, %UnsetStatement{} = statement) do
    %{
      table: table,
      file: key,
      line: line,
      index: index,
      kind: :unset,
      field: statement.field.name,
      value_expr: nil,
      where_expr: statement.where_expr,
      reads: reads([statement.where_expr]),
      source: AST.unparse(statement),
    }
  end

  # Field names an expression reads, in first-read order.
  defp reads(exprs) do
    exprs
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(fn expr ->
      {_expr, names} =
        AST.prewalk(expr, [], fn
          %AST.Node.Identifier{name: name} = node, names -> {node, [name | names]}
          node, names -> {node, names}
        end)

      Enum.reverse(names)
    end)
    |> Enum.uniq()
  end

  # Nodes that parse as expressions but cannot be evaluated on one event.
  @not_scalar [
    {AST.Node.AggregateFunctionCall, "aggregate functions"},
    {AST.Node.Splat, "*"},
    {AST.Node.As, "AS"},
    {AST.Node.Ascending, "ASC"},
    {AST.Node.Descending, "DESC"},
  ]

  defp expression_errors(statement) do
    [statement.value_expr, statement.where_expr]
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(fn expr ->
      {_expr, found} =
        AST.prewalk(expr, [], fn %mod{} = node, found ->
          case List.keyfind(@not_scalar, mod, 0) do
            {_mod, what} -> {node, [what | found]}
            nil -> {node, found}
          end
        end)

      found
    end)
    |> Enum.uniq()
    |> Enum.map(fn what ->
      error(
        statement.file,
        statement.line,
        :expression,
        "#{statement.field}: #{what}",
        "rules cannot use #{what}",
        statement.table
      )
    end)
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

    limit_errors ++ conflict_errors(table, statements) ++ cycle_errors(table, statements)
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

  # SET statements form a dependency graph: a SET depends on every other SET whose
  # field it reads (a read of `user.name` reads the top-level field `user`).
  defp cycle_errors(table, statements) do
    case order_sets(Enum.filter(statements, &(&1.kind == :set))) do
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
    {:ok, sets} = order_sets(Enum.filter(statements, &(&1.kind == :set)))
    unsets = Enum.filter(statements, &(&1.kind == :unset))
    steps = sets ++ unsets
    # File and line too: compiled modules report them when a statement fails.
    identity = Enum.map(steps, &{&1.file, &1.line, &1.source})
    hash = :crypto.hash(:sha256, :erlang.term_to_binary(identity))
    %Rules.Plan{table: table, steps: steps, hash: Base.encode16(hash, case: :lower)}
  end

  # Kahn's algorithm, always taking the earliest ready statement (by file, then
  # position), so independent statements run in file-name then statement order.
  defp order_sets(sets) do
    by_field = Map.new(sets, &{&1.field, &1})

    deps =
      Map.new(sets, fn set ->
        fields =
          set.reads
          |> Enum.map(&top_level/1)
          |> Enum.filter(&(Map.has_key?(by_field, &1) and &1 != set.field))
          |> MapSet.new()

        {set.field, fields}
      end)

    order(Enum.sort_by(sets, &{&1.file, &1.index}), deps, [])
  end

  defp order([], _deps, acc), do: {:ok, Enum.reverse(acc)}

  defp order(pending, deps, acc) do
    case Enum.find(pending, &(MapSet.size(Map.fetch!(deps, &1.field)) == 0)) do
      nil ->
        {:cycle, pending}

      ready ->
        deps =
          Map.new(deps, fn {field, fields} -> {field, MapSet.delete(fields, ready.field)} end)

        order(List.delete(pending, ready), deps, [ready | acc])
    end
  end

  @doc "The top-level field of a field name or path (`user` for `user.name`)."
  def top_level(name), do: name |> String.split(".", parts: 2) |> hd()

  defp error(file, line, kind, detail, message, table) do
    location = if line, do: "#{file} line #{line}", else: file

    %{
      table: table,
      file: file,
      line: line,
      kind: kind,
      detail: detail,
      message: "#{location}: #{message}",
    }
  end
end
