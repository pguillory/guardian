defmodule Guardian.Query.Resolver do
  @moduledoc """
  Transform queries to a simpler form that contains only SELECT statements.

  Operations:
  - Convert SHOW TABLES and DESC to SELECT
  - LET substitutions
  - Match column names to stored column names ignoring case
  - Convert splat (SELECT *) into list of fields
  - Label each statement's columns (`labels/1`)
  """

  alias Guardian.AST.Node.Operators.EqualOperator

  alias Guardian.AST.Node.Statements.DescStatement
  alias Guardian.AST.Node.Statements.LetStatement
  alias Guardian.AST.Node.Statements.NullStatement
  alias Guardian.AST.Node.Statements.SelectStatement
  alias Guardian.AST.Node.Statements.ShowTablesStatement

  @doc """
  Resolves SQL text into its executable statements, each paired with its column labels
  (`labels/1` of the statement before LET substitution, so the labels name columns in
  their stored spelling and keep LET names as written). LET and empty statements yield
  no pair.
  """
  @spec resolve(String.t()) :: [{struct(), [String.t()]}]
  def resolve(source) when is_binary(source) do
    statements = Guardian.AST.parse_statements(source)
    statements = Enum.map(statements, &resolve_show_desc/1)
    statements = Enum.map(statements, &resolve_aliases/1)

    # Labels come from the pre-LET statements. Pair each with the LET names bound
    # before it, which are not columns there.
    {raw_statements, _let_names} =
      Enum.flat_map_reduce(statements, MapSet.new(), fn
        %NullStatement{}, let_names ->
          {[], let_names}

        %LetStatement{key_expr: %Guardian.AST.Node.Identifier{name: name}}, let_names ->
          {[], MapSet.put(let_names, name)}

        %LetStatement{}, let_names ->
          {[], let_names}

        statement, let_names ->
          {[{statement, let_names}], let_names}
      end)

    # LET may substitute table names, so tables are read from substituted statements.
    statements = resolve_let_statements(statements)
    columns = table_columns(statements)

    statements = Enum.map(statements, &resolve_columns(&1, columns, MapSet.new()))

    labels =
      raw_statements
      |> SuperList.zip(statements)
      |> Enum.map(fn {{raw_statement, let_names}, statement} ->
        raw_statement
        |> copy_tables(statement)
        |> resolve_columns(columns, let_names)
        |> labels()
      end)

    SuperList.zip(statements, labels)
  end

  @doc """
  The column labels of a statement: an alias where one is given, else the expression
  as written back by `Guardian.AST.unparse/1`.
  """
  @spec labels(struct()) :: [String.t()]
  def labels(%SelectStatement{} = statement) do
    statement.select_exprs |> Enum.map(&label/1)
  end

  def labels(%ShowTablesStatement{}) do
    ["table"]
  end

  def labels(%DescStatement{}) do
    ["key"]
  end

  defp label(%Guardian.AST.Node.As{right: %Guardian.AST.Node.Identifier{name: name}}) do
    name
  end

  defp label(%Guardian.AST.Node.As{right: %Guardian.AST.Node.Literal{value: value}})
       when is_binary(value) do
    value
  end

  defp label(expr) do
    Guardian.AST.unparse(expr)
  end

  # Column names resolve before SELECT * expands:
  # expanded names are exact stored names and would trip the ambiguity check on a
  # table holding two spellings of one name.
  defp resolve_columns(statement, columns, skip_names) do
    statement
    |> resolve_column_names(columns, skip_names)
    |> resolve_select_star(columns)
  end

  defp copy_tables(%SelectStatement{} = raw, %SelectStatement{} = statement) do
    %SelectStatement{raw | from_expr: statement.from_expr}
  end

  defp copy_tables(raw, _statement) do
    raw
  end

  defp table_columns(statements) do
    statements
    |> Enum.flat_map(fn
      %SelectStatement{from_expr: %Guardian.AST.Node.Identifier{name: table}} ->
        [table]

      _ ->
        []
    end)
    |> Enum.uniq()
    |> Map.new(&{&1, keys(&1)})
  end

  defp resolve_column_names(
         %SelectStatement{from_expr: %Guardian.AST.Node.Identifier{name: table}} = statement,
         columns,
         skip_names
       ) do
    index = column_index(Map.fetch!(columns, table))
    resolve = &resolve_expr_columns(&1, index, skip_names)
    resolve_list = fn exprs -> exprs && Enum.map(exprs, resolve) end

    %SelectStatement{
      statement
      | select_exprs: Enum.map(statement.select_exprs, resolve),
        where_expr: statement.where_expr && resolve.(statement.where_expr),
        group_by_exprs: resolve_list.(statement.group_by_exprs),
        having_expr: statement.having_expr && resolve.(statement.having_expr),
        order_by_exprs: resolve_list.(statement.order_by_exprs),
    }
  end

  defp resolve_column_names(statement, _columns, _skip_names) do
    statement
  end

  # The right side of AS is an alias, not a column, wherever AS appears. AST traversal
  # always descends into both sides, so an AS node is resolved here and parked in a
  # childless Literal until the post step puts it back.
  defp resolve_expr_columns(expr, index, skip_names) do
    pre = fn
      %Guardian.AST.Node.As{left: left} = expr, acc ->
        left = resolve_expr_columns(left, index, skip_names)

        {%Guardian.AST.Node.Literal{
           value: {:resolved_as, %Guardian.AST.Node.As{expr | left: left}},
         }, acc}

      expr, acc ->
        {expr, acc}
    end

    post = fn
      %Guardian.AST.Node.Literal{value: {:resolved_as, expr}}, acc ->
        {expr, acc}

      %Guardian.AST.Node.Identifier{name: name} = expr, acc ->
        if MapSet.member?(skip_names, name) do
          {expr, acc}
        else
          {%Guardian.AST.Node.Identifier{name: resolve_column_name(name, index)}, acc}
        end

      expr, acc ->
        {expr, acc}
    end

    {expr, nil} = Guardian.AST.traverse(expr, nil, pre, post)
    expr
  end

  defp column_index(keys) do
    Enum.group_by(keys, &String.downcase/1)
  end

  defp resolve_column_name(name, index) do
    case Map.get(index, String.downcase(name), []) do
      [] ->
        name

      [stored] ->
        stored

      matches ->
        raise Guardian.Query.AmbiguousColumnError, name: name, matches: Enum.sort(matches)
    end
  end

  def resolve_show_desc(%ShowTablesStatement{}) do
    %SelectStatement{
      select_exprs: [
        %Guardian.AST.Node.Identifier{name: "table"},
      ],
      from_expr: %Guardian.AST.Node.Identifier{name: "schema"},
      group_by_exprs: [
        %Guardian.AST.Node.Identifier{name: "table"},
      ],
      order_by_exprs: [
        %Guardian.AST.Node.Identifier{name: "table"},
      ],
    }
  end

  def resolve_show_desc(%DescStatement{expr: expr}) do
    %Guardian.AST.Node.Identifier{name: table} = expr

    %SelectStatement{
      select_exprs: [
        %Guardian.AST.Node.Identifier{name: "key"},
        # %Guardian.AST.Node.Identifier{name: "count"},
        # %Guardian.AST.Node.Identifier{name: "null_count"},
        # %Guardian.AST.Node.As{
        #   left: %AddOperator{
        #     left: %Guardian.AST.Node.Identifier{name: "false_count"},
        #     right: %Guardian.AST.Node.Identifier{name: "true_count"},
        #   },
        #   right: %Guardian.AST.Node.Identifier{name: "boolean_count"},
        # },
        # %Guardian.AST.Node.As{
        #   left: %AddOperator{
        #     left: %Guardian.AST.Node.Identifier{name: "int_count"},
        #     right: %Guardian.AST.Node.Identifier{name: "float_count"},
        #   },
        #   right: %Guardian.AST.Node.Identifier{name: "number_count"},
        # },
        # %Guardian.AST.Node.Identifier{name: "string_count"},
      ],
      from_expr: %Guardian.AST.Node.Identifier{name: "schema"},
      where_expr: %EqualOperator{
        left: %Guardian.AST.Node.Identifier{name: "table"},
        right: %Guardian.AST.Node.Literal{value: table},
      },
      order_by_exprs: [
        %Guardian.AST.Node.Identifier{name: "key"},
      ],
    }
  end

  def resolve_show_desc(statement) do
    statement
  end

  defp resolve_let_statements([%NullStatement{} | statements]) do
    resolve_let_statements(statements)
  end

  defp resolve_let_statements([%LetStatement{} = let_statement | statements]) do
    case let_statement.key_expr do
      %Guardian.AST.Node.Identifier{} = key_expr ->
        Enum.map(statements, fn statement ->
          Guardian.AST.postwalk(statement, fn
            ^key_expr ->
              let_statement.value_expr

            expr ->
              expr
          end)
        end)

      %Guardian.AST.Node.FunctionCall{name: name, args: arg_keys} ->
        Enum.map(statements, fn statement ->
          Guardian.AST.postwalk(statement, fn
            %Guardian.AST.Node.FunctionCall{name: ^name, args: arg_values} ->
              if length(arg_keys) != length(arg_values) do
                raise "Wrong number of arguments to LET function #{inspect(name)}"
              end

              replacement_map = Enum.zip(arg_keys, arg_values) |> Map.new()

              Guardian.AST.postwalk(let_statement.value_expr, fn expr ->
                Map.get(replacement_map, expr, expr)
              end)

            expr ->
              expr
          end)
        end)
    end
    |> resolve_let_statements()
  end

  defp resolve_let_statements([statement | statements]) do
    [statement | resolve_let_statements(statements)]
  end

  defp resolve_let_statements([]) do
    []
  end

  defp resolve_select_star(%SelectStatement{} = statement, columns) do
    update_in(statement.select_exprs, fn select_exprs ->
      Enum.flat_map(select_exprs, fn
        %Guardian.AST.Node.Splat{} ->
          %Guardian.AST.Node.Identifier{name: table} = statement.from_expr
          keys = Map.fetch!(columns, table)
          Enum.map(keys, &%Guardian.AST.Node.Identifier{name: &1})

        expr ->
          [expr]
      end)
    end)
  end

  defp resolve_select_star(statement, _columns) do
    statement
  end

  defp keys("schema") do
    Guardian.Query.VirtualTable.Schema.keys()
  end

  defp keys(table) do
    Guardian.Cluster.Metadata.schema(table)
    |> Map.keys()
    |> Enum.sort()
  end

  def resolve_aliases(source) when is_binary(source) do
    statements = Guardian.AST.parse_statements(source)
    statements = Enum.map(statements, &resolve_aliases/1)
    Enum.map_join(statements, ";\n", &Guardian.AST.unparse/1)
  end

  def resolve_aliases(%SelectStatement{} = statement) do
    select_expr_aliases =
      statement.select_exprs
      |> Enum.flat_map(fn
        %Guardian.AST.Node.As{left: left_expr, right: %Guardian.AST.Node.Identifier{name: name}} ->
          [{name, left_expr}]

        _ ->
          []
      end)
      |> Map.new()

    resolve = fn
      nil ->
        nil

      group_by_expr ->
        Guardian.AST.postwalk(group_by_expr, fn
          %Guardian.AST.Node.Identifier{name: name} = expr ->
            Map.get(select_expr_aliases, name, expr)

          expr ->
            expr
        end)
    end

    resolve_list = fn
      nil ->
        nil

      group_by_exprs ->
        Enum.map(group_by_exprs, resolve)
    end

    statement = update_in(statement.group_by_exprs, resolve_list)
    statement = update_in(statement.having_expr, resolve)
    statement = update_in(statement.order_by_exprs, resolve_list)
    statement
  end

  def resolve_aliases(statement) do
    statement
  end

  def unresolve_statement_index(query, statement_index) when is_binary(query) do
    statements = Guardian.AST.parse_statements(query)
    unresolve_statement_index(statements, statement_index)
  end

  def unresolve_statement_index(statements, statement_index) when is_list(statements) do
    unresolve_statement_index(statements, statement_index, 0)
  end

  def unresolve_statement_index([%LetStatement{} | statements], statement_index, unresolved_index) do
    unresolve_statement_index(statements, statement_index, unresolved_index + 1)
  end

  def unresolve_statement_index(_statements, 0, unresolved_index) do
    unresolved_index
  end

  def unresolve_statement_index([_ | statements], statement_index, unresolved_index) do
    unresolve_statement_index(statements, statement_index - 1, unresolved_index + 1)
  end
end
