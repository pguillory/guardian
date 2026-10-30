defmodule Guardian.Query.Resolver do
  @moduledoc """
  Transform queries to a simpler form that contains only SELECT statements.

  Operations:
  - Convert SHOW TABLES and DESC to SELECT
  - LET substitutions
  - Convert splat (SELECT *) into list of fields
  - Label each statement's columns
  """

  alias Guardian.AST
  alias Guardian.AST.Node.As
  alias Guardian.AST.Node.FunctionCall
  alias Guardian.AST.Node.Identifier
  alias Guardian.AST.Node.Literal
  alias Guardian.AST.Node.Operators.EqualOperator
  alias Guardian.AST.Node.Splat

  alias Guardian.AST.Node.Statements.DescStatement
  alias Guardian.AST.Node.Statements.LetStatement
  alias Guardian.AST.Node.Statements.NullStatement
  alias Guardian.AST.Node.Statements.SelectStatement
  alias Guardian.AST.Node.Statements.ShowTablesStatement

  @doc """
  Resolves SQL text into its executable statements, each paired with its column labels
  (an alias where one is given, else the expression as written, taken from the
  statement before LET substitution, so the labels keep LET names as written). LET and
  empty statements yield no pair.
  """
  @spec resolve(String.t()) :: [{struct(), [String.t()]}]
  def resolve(source) when is_binary(source) do
    statements = AST.parse_statements(source)
    statements = Enum.map(statements, &resolve_show_desc/1)
    statements = Enum.map(statements, &resolve_aliases/1)

    # Labels come from the pre-LET statements.
    raw_statements =
      Enum.reject(statements, &(is_struct(&1, NullStatement) or is_struct(&1, LetStatement)))

    # LET may substitute table names, so tables are read from substituted statements.
    statements = resolve_let_statements(statements)
    columns = table_columns(statements)

    statements = Enum.map(statements, &resolve_select_star(&1, columns))

    labels =
      raw_statements
      |> SuperList.zip(statements)
      |> Enum.map(fn {raw_statement, statement} ->
        raw_statement
        |> copy_tables(statement)
        |> resolve_select_star(columns)
        |> labels()
      end)

    SuperList.zip(statements, labels)
  end

  # The column labels of a SELECT: an alias where one is given, else the expression
  # as written back by `Guardian.AST.unparse/1`. SHOW TABLES and DESC are SELECTs by
  # now (`resolve_show_desc/1`).
  defp labels(%SelectStatement{} = statement) do
    statement.select_exprs |> Enum.map(&label/1)
  end

  defp label(%As{right: %Identifier{name: name}}) do
    name
  end

  defp label(%As{right: %Literal{value: value}})
       when is_binary(value) do
    value
  end

  defp label(expr) do
    AST.unparse(expr)
  end

  defp copy_tables(%SelectStatement{} = raw, %SelectStatement{} = statement) do
    %SelectStatement{raw | from_expr: statement.from_expr}
  end

  defp copy_tables(raw, _statement) do
    raw
  end

  # The columns of each table a SELECT * reads, the only use of a table's schema in
  # resolution, so other SELECTs make no cluster schema lookup. Read from the
  # statements after LET substitution, which can add a top-level * but never remove one.
  defp table_columns(statements) do
    statements
    |> Enum.flat_map(fn
      %SelectStatement{from_expr: %Identifier{name: table}} = statement ->
        if select_star?(statement), do: [table], else: []

      _ ->
        []
    end)
    |> Enum.uniq()
    |> Map.new(&{&1, keys(&1)})
  end

  defp select_star?(%SelectStatement{select_exprs: select_exprs}) do
    Enum.any?(select_exprs, &is_struct(&1, Splat))
  end

  def resolve_show_desc(%ShowTablesStatement{}) do
    %SelectStatement{
      select_exprs: [
        %Identifier{name: "table"},
      ],
      from_expr: %Identifier{name: "schema"},
      group_by_exprs: [
        %Identifier{name: "table"},
      ],
      order_by_exprs: [
        %Identifier{name: "table"},
      ],
    }
  end

  def resolve_show_desc(%DescStatement{expr: expr}) do
    %Identifier{name: table} = expr

    %SelectStatement{
      select_exprs: [
        %Identifier{name: "key"},
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
      from_expr: %Identifier{name: "schema"},
      where_expr: %EqualOperator{
        left: %Identifier{name: "table"},
        right: %Literal{value: table},
      },
      order_by_exprs: [
        %Identifier{name: "key"},
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
      %Identifier{} = key_expr ->
        Enum.map(statements, fn statement ->
          AST.postwalk(statement, fn
            ^key_expr ->
              let_statement.value_expr

            expr ->
              expr
          end)
        end)

      %FunctionCall{name: name, args: arg_keys} ->
        Enum.map(statements, fn statement ->
          AST.postwalk(statement, fn
            %FunctionCall{name: ^name, args: arg_values} ->
              if length(arg_keys) != length(arg_values) do
                raise "Wrong number of arguments to LET function #{inspect(name)}"
              end

              replacement_map = Enum.zip(arg_keys, arg_values) |> Map.new()

              AST.postwalk(let_statement.value_expr, fn expr ->
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
        %Splat{} ->
          case statement.from_expr do
            %Identifier{name: table} ->
              columns |> Map.fetch!(table) |> Enum.map(&%Identifier{name: &1})

            _ ->
              raise Guardian.Query.Error, message: "SELECT * needs FROM and a table name"
          end

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
    statements = AST.parse_statements(source)
    statements = Enum.map(statements, &resolve_aliases/1)
    Enum.map_join(statements, ";\n", &AST.unparse/1)
  end

  def resolve_aliases(%SelectStatement{} = statement) do
    select_expr_aliases =
      statement.select_exprs
      |> Enum.flat_map(fn
        %As{left: left_expr, right: %Identifier{name: name}} ->
          [{name, left_expr}]

        _ ->
          []
      end)
      |> Map.new()

    resolve = fn
      nil ->
        nil

      group_by_expr ->
        AST.postwalk(group_by_expr, fn
          %Identifier{name: name} = expr ->
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
    statements = AST.parse_statements(query)
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
