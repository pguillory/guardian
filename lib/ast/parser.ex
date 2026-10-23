defmodule AST.Parser do
  alias AST.ParseError
  alias AST.Tokenizer

  alias AST.Node.Operators.AddOperator
  alias AST.Node.Operators.AndOperator
  alias AST.Node.Operators.BetweenOperator
  alias AST.Node.Operators.ConcatOperator
  alias AST.Node.Operators.DivideOperator
  alias AST.Node.Operators.EqualOperator
  alias AST.Node.Operators.GreaterThanOperator
  alias AST.Node.Operators.GreaterThanOrEqualOperator
  alias AST.Node.Operators.IlikeOperator
  alias AST.Node.Operators.InOperator
  alias AST.Node.Operators.IsNotOperator
  alias AST.Node.Operators.IsOperator
  alias AST.Node.Operators.LessThanOperator
  alias AST.Node.Operators.LessThanOrEqualOperator
  alias AST.Node.Operators.LikeOperator
  alias AST.Node.Operators.ListLiteral
  alias AST.Node.Operators.MultiplyOperator
  alias AST.Node.Operators.NegativeOperator
  alias AST.Node.Operators.NotEqualOperator
  alias AST.Node.Operators.NotIlikeOperator
  alias AST.Node.Operators.NotLikeOperator
  alias AST.Node.Operators.NotOperator
  alias AST.Node.Operators.NotRlikeOperator
  alias AST.Node.Operators.NullSafeEqualOperator
  alias AST.Node.Operators.OrOperator
  alias AST.Node.Operators.RlikeOperator
  alias AST.Node.Operators.SubtractOperator

  alias AST.Node.As
  alias AST.Node.Ascending
  alias AST.Node.Descending
  alias AST.Node.Literal

  alias AST.Node.Statements.DescStatement
  alias AST.Node.Statements.LetStatement
  alias AST.Node.Statements.NullStatement
  alias AST.Node.Statements.SelectStatement
  alias AST.Node.Statements.ShowTablesStatement

  # Infix and postfix operators, tightest-binding tier first. An operator's syntax is its
  # node's `symbol/0`, the spelling `to_source/1` prints: each word is a keyword token,
  # anything else one punctuation token. Precedence counts up from the loosest tier, 1.
  # `parse_operand/4` handles the nodes that are not plain `left SYM right`.
  @operator_tiers [
    [MultiplyOperator, DivideOperator],
    [AddOperator, SubtractOperator, ConcatOperator],
    [
      LessThanOperator,
      LessThanOrEqualOperator,
      GreaterThanOperator,
      GreaterThanOrEqualOperator,
      NullSafeEqualOperator,
      EqualOperator,
      NotEqualOperator,
      IsOperator,
      IsNotOperator,
      LikeOperator,
      IlikeOperator,
      RlikeOperator,
      NotLikeOperator,
      NotIlikeOperator,
      NotRlikeOperator,
      InOperator,
    ],
    [BetweenOperator],
    [AndOperator],
    [OrOperator],
    [As, Ascending, Descending],
  ]

  # {tokens, module, precedence}, longest tokens first so that IS NOT is tried before IS.
  @operators (for {modules, precedence} <-
                    @operator_tiers |> Enum.reverse() |> Enum.with_index(1),
                  module <- modules do
                tokens =
                  for word <- String.split(module.symbol(), " ") do
                    if word =~ ~r/^[A-Z]+$/, do: {:keyword, word}, else: {:punctuation, word}
                  end

                {tokens, module, precedence}
              end)
             |> Enum.sort_by(fn {tokens, _, _} -> length(tokens) end, :desc)

  # continue_expression/3 takes the longest operator matching the tokens, then checks its
  # precedence. That is only right if operators whose tokens start another's (IS and IS
  # NOT) share a tier; and every token must be one the tokenizer produces.
  for {tokens1, module1, precedence1} <- @operators,
      {tokens2, module2, precedence2} <- @operators,
      module1 != module2,
      List.starts_with?(tokens2, tokens1),
      precedence1 != precedence2 do
    raise "#{inspect(module1)} and #{inspect(module2)} share a token prefix but not a tier"
  end

  for {tokens, module, _} <- @operators,
      {type, word} <- tokens,
      word not in if(type == :keyword, do: Tokenizer.keywords(), else: Tokenizer.punctuation()) do
    raise "#{inspect(module)}'s symbol has #{word}, which is not a #{type} token"
  end

  @precedences Map.new(@operators, fn {_tokens, module, precedence} -> {module, precedence} end)

  def parse(source) when is_binary(source) do
    with_source_parsed(source, fn tokens ->
      parse_statements_or_expression!(tokens)
    end)
  end

  def parse_statements(source) when is_binary(source) do
    with_source_parsed(source, fn tokens ->
      parse_statements!(tokens)
    end)
  end

  def parse_expression(source) when is_binary(source) do
    with_source_parsed(source, fn tokens ->
      parse_expression!(tokens)
    end)
  end

  defp with_source_parsed(source, func) do
    case func.(Tokenizer.tokenize(source)) do
      {expr, []} ->
        expr

      {_expr, [_ | _] = tokens} ->
        throw {:expected, "end of input", tokens}
    end
  catch
    {:expected, expected, remaining_tokens} ->
      found = describe_found(source, remaining_tokens)
      raise_parse_error(source, "Expected #{expected}, got #{found}", remaining_tokens)

    {:parse_error, reason, remaining_tokens} ->
      raise_parse_error(source, reason, remaining_tokens)
  end

  defp raise_parse_error(source, reason, remaining_tokens) do
    {row, col} = Tokenizer.position(source, remaining_tokens)
    raise ParseError, reason: reason, row: row, col: col
  end

  defp describe_found(source, remaining_tokens) do
    case Tokenizer.next_raw_token(source, remaining_tokens) do
      nil ->
        "end of input"

      raw_token ->
        [first_line | _] = String.split(raw_token, "\n")

        if first_line != raw_token or String.length(first_line) > 40 do
          String.slice(first_line, 0, 40) <> "..."
        else
          raw_token
        end
    end
  end

  defp parse_statements_or_expression!(tokens) do
    with nil <- maybe_parse_statements_or_expression(tokens) do
      throw {:expected, "statements or expression", tokens}
    end
  end

  defp maybe_parse_statements_or_expression(tokens) do
    with nil <- maybe_parse_statements(tokens),
         nil <- maybe_parse_expression(tokens) do
      nil
    end
  end

  defp parse_statements!(tokens) do
    with nil <- maybe_parse_statements(tokens) do
      throw {:expected, "statements", tokens}
    end
  end

  defp maybe_parse_statements(tokens) do
    case tokens do
      [] ->
        {[], []}

      [_ | _] ->
        case maybe_parse_statement(tokens) do
          {statement, tokens} ->
            continue_statements(tokens, [statement])

          nil ->
            nil
        end
    end
  end

  defp continue_statements(tokens, statements) do
    case tokens do
      [{:punctuation, ";"}] ->
        statement = %NullStatement{}
        tokens = []
        continue_statements(tokens, [statement | statements])

      [{:punctuation, ";"} | tokens] ->
        {statement, tokens} = parse_statement!(tokens)
        continue_statements(tokens, [statement | statements])

      [] ->
        {Enum.reverse(statements), []}

      _ ->
        throw {:expected, "end of statement", tokens}
    end
  end

  defp parse_statement!(tokens) do
    with nil <- maybe_parse_statement(tokens) do
      throw {:expected, "statement", tokens}
    end
  end

  defp maybe_parse_statement(tokens) do
    with nil <- maybe_parse_null_statement(tokens),
         nil <- maybe_parse_select_statement(tokens),
         nil <- maybe_parse_show_tables_statement(tokens),
         nil <- maybe_parse_desc_statement(tokens),
         nil <- maybe_parse_let_statement(tokens) do
      nil
    end
  end

  defp maybe_parse_null_statement(tokens) do
    case tokens do
      [{:punctuation, ";"} | _] ->
        {%NullStatement{}, tokens}

      _ ->
        nil
    end
  end

  defp maybe_parse_select_statement(tokens) do
    case tokens do
      [{:keyword, "SELECT"} | tokens] ->
        {exprs, tokens} = parse_expression_list!(tokens)
        statement = %SelectStatement{select_exprs: exprs}
        continue_select_statement(tokens, statement)

      _ ->
        nil
    end
  end

  defp continue_select_statement(tokens, %SelectStatement{} = statement) do
    case tokens do
      [{:keyword, "FROM"} | tokens] = bad_tokens ->
        if statement.from_expr do
          throw {:parse_error, "Duplicate FROM clause", bad_tokens}
        end

        {expr, tokens} = parse_expression!(tokens)
        statement = put_in(statement.from_expr, expr)
        continue_select_statement(tokens, statement)

      [{:keyword, "WHERE"} | tokens] ->
        {where_expr, tokens} = parse_expression!(tokens)
        statement = update_in(statement.where_expr, &amend_where_expr(&1, where_expr))
        continue_select_statement(tokens, statement)

      [{:keyword, "GROUP"}, {:keyword, "BY"} | tokens] = bad_tokens ->
        if statement.group_by_exprs do
          throw {:parse_error, "Duplicate GROUP BY clause", bad_tokens}
        end

        {exprs, tokens} = parse_expression_list!(tokens)
        statement = put_in(statement.group_by_exprs, exprs)
        continue_select_statement(tokens, statement)

      [{:keyword, "HAVING"} | tokens] = bad_tokens ->
        if statement.having_expr do
          throw {:parse_error, "Duplicate HAVING clause", bad_tokens}
        end

        {expr, tokens} = parse_expression!(tokens)
        statement = put_in(statement.having_expr, expr)
        continue_select_statement(tokens, statement)

      [{:keyword, "ORDER"}, {:keyword, "BY"} | tokens] = bad_tokens ->
        if statement.order_by_exprs do
          throw {:parse_error, "Duplicate ORDER BY clause", bad_tokens}
        end

        {exprs, tokens} = parse_expression_list!(tokens)
        statement = put_in(statement.order_by_exprs, exprs)
        continue_select_statement(tokens, statement)

      [{:keyword, "LIMIT"} | tokens] = bad_tokens ->
        if statement.limit_expr do
          throw {:parse_error, "Duplicate LIMIT clause", bad_tokens}
        end

        {expr, tokens} = parse_integer_literal!(tokens)
        statement = put_in(statement.limit_expr, expr)
        continue_select_statement(tokens, statement)

      _ ->
        {statement, tokens}
    end
  end

  defp amend_where_expr(nil, where_expr), do: where_expr

  defp amend_where_expr(previous_where_expr, where_expr) do
    %AndOperator{left: previous_where_expr, right: where_expr}
  end

  defp continue_case_expression(tokens, %AST.Node.Case{} = expr) do
    case tokens do
      [{:keyword, "WHEN"} | tokens] ->
        {when_expr, tokens} = parse_expression!(tokens)
        expr = update_in(expr.when_exprs, &(&1 ++ [when_expr]))
        tokens = parse_keyword!(tokens, "THEN")
        {then_expr, tokens} = parse_expression!(tokens)
        expr = update_in(expr.then_exprs, &(&1 ++ [then_expr]))
        continue_case_expression(tokens, expr)

      [{:keyword, "ELSE"} | tokens] ->
        {else_expr, tokens} = parse_expression!(tokens)
        expr = put_in(expr.else_expr, else_expr)
        tokens = parse_keyword!(tokens, "END")
        {expr, tokens}

      [{:keyword, "END"} | tokens] ->
        {expr, tokens}

      _ ->
        throw {:expected, "WHEN, ELSE, or END keyword", tokens}
    end
  end

  defp parse_keyword!(tokens, keyword) do
    case tokens do
      [{:keyword, ^keyword} | tokens] ->
        tokens

      _ ->
        throw {:expected, "#{keyword} keyword", tokens}
    end
  end

  defp maybe_parse_show_tables_statement(tokens) do
    case tokens do
      [{:keyword, "SHOW"}, {:keyword, "TABLES"} | tokens] ->
        {%ShowTablesStatement{}, tokens}

      _ ->
        nil
    end
  end

  defp maybe_parse_desc_statement(tokens) do
    case tokens do
      [{:keyword, "DESC"} | tokens] ->
        {expr, tokens} = parse_expression!(tokens)
        {%DescStatement{expr: expr}, tokens}

      _ ->
        nil
    end
  end

  defp maybe_parse_let_statement(tokens) do
    case tokens do
      [{:keyword, "LET"} | tokens] ->
        {key_expr, tokens} = parse_identifier_or_function_call!(tokens)
        tokens = parse_punctuation!(tokens, "=")
        {value_expr, tokens} = parse_expression!(tokens)
        {%LetStatement{key_expr: key_expr, value_expr: value_expr}, tokens}

      _ ->
        nil
    end
  end

  defp parse_identifier_or_function_call!(tokens) do
    with nil <- maybe_parse_identifier_or_function_call(tokens) do
      throw {:expected, "identifier or function call", tokens}
    end
  end

  defp maybe_parse_identifier_or_function_call(tokens) do
    with nil <- maybe_parse_function_call(tokens),
         nil <- maybe_parse_identifier(tokens) do
      nil
    end
  end

  defp parse_expression_list!(tokens) do
    {expr, tokens} = parse_expression!(tokens)
    continue_expression_list(tokens, [expr])
  end

  defp continue_expression_list(tokens, exprs) do
    case tokens do
      [{:punctuation, ","} | tokens] ->
        {expr, tokens} = parse_expression!(tokens)
        continue_expression_list(tokens, exprs ++ [expr])

      _ ->
        {exprs, tokens}
    end
  end

  defp parse_expression!(tokens, precedence \\ 0) do
    with nil <- maybe_parse_expression(tokens, precedence) do
      throw {:expected, "expression", tokens}
    end
  end

  defp maybe_parse_expression(tokens, precedence \\ 0) do
    with nil <- maybe_parse_function_call(tokens),
         nil <- maybe_parse_identifier(tokens),
         nil <- maybe_parse_literal(tokens),
         nil <- maybe_parse_parentheses(tokens),
         nil <- maybe_parse_list_literal(tokens),
         nil <- maybe_parse_unary_operator(tokens),
         nil <- maybe_parse_mysql_interval(tokens),
         nil <- maybe_parse_splat(tokens),
         nil <- maybe_parse_case_expression(tokens) do
      nil
    else
      {expr, tokens} ->
        continue_expression(tokens, expr, precedence)
    end
  end

  defp maybe_parse_function_call(tokens_at_function) do
    case tokens_at_function do
      [
        {:identifier, "count"},
        {:punctuation, "("},
        {:punctuation, "*"},
        {:punctuation, ")"} | tokens,
      ] ->
        expr = %AST.Node.AggregateFunctionCall{name: "count", args: []}
        {expr, tokens}

      [{:identifier, name}, {:punctuation, "("} | tokens]
      when name in unquote(Aggregation.names()) ->
        {exprs, tokens} = parse_expression_list_and_closing_parenthesis!(tokens)

        unless {name, length(exprs)} in Aggregation.names_and_arities() do
          throw {:parse_error, "Wrong number of parameters for aggregate function #{name}",
                 tokens_at_function}
        end

        expr = %AST.Node.AggregateFunctionCall{name: name, args: exprs}
        {expr, tokens}

      [{:identifier, "replace"}, {:punctuation, "("} | tokens] ->
        {arg1, tokens} = parse_expression!(tokens)
        tokens = parse_punctuation!(tokens, ",")
        {arg2, tokens} = parse_regex!(tokens)
        tokens = parse_punctuation!(tokens, ",")
        {arg3, tokens} = parse_expression!(tokens)
        tokens = parse_punctuation!(tokens, ")")
        expr = %AST.Node.FunctionCall{name: "replace", args: [arg1, arg2, arg3]}
        {expr, tokens}

      [{:identifier, name}, {:punctuation, "("} | tokens]
      when name in unquote(Query.Function.names()) ->
        {exprs, tokens} = parse_expression_list_and_closing_parenthesis!(tokens)

        unless {name, length(exprs)} in Query.Function.names_and_arities() do
          throw {:parse_error, "Wrong number of parameters for function #{name}",
                 tokens_at_function}
        end

        expr = %AST.Node.FunctionCall{name: name, args: exprs}
        {expr, tokens}

      [{:identifier, name}, {:punctuation, "("} | _tokens] ->
        # {exprs, tokens} = parse_expression_list_and_closing_parenthesis!(tokens)
        # expr = %FunctionCall{name: name, args: exprs}
        # {expr, tokens}

        throw {:parse_error, "Invalid function #{name}", tokens_at_function}

      _ ->
        nil
    end
  end

  defp parse_expression_list_and_closing_parenthesis!(tokens) do
    case tokens do
      [{:punctuation, ")"} | tokens] ->
        {[], tokens}

      _ ->
        {exprs, tokens} = parse_expression_list!(tokens)
        tokens = parse_punctuation!(tokens, ")")
        {exprs, tokens}
    end
  end

  defp maybe_parse_identifier(tokens) do
    case tokens do
      [{:identifier, name} | tokens] ->
        case String.downcase(name) do
          "current_date" ->
            expr = %AST.Node.FunctionCall{name: "current_date", args: []}
            {expr, tokens}

          "current_timestamp" ->
            expr = %AST.Node.FunctionCall{name: "current_timestamp", args: []}
            {expr, tokens}

          _ ->
            expr = %AST.Node.Identifier{name: name}
            {expr, tokens}
        end

      _ ->
        nil
    end
  end

  defguardp is_literal_token(type, value)
            when (type == :null and value == nil) or (type == false and value == false) or
                   (type == true and value == true) or (type == :integer and is_integer(value)) or
                   (type == :float and is_float(value)) or (type == :string and is_binary(value))

  defp maybe_parse_literal(tokens) do
    case tokens do
      [{type, value} | tokens] when is_literal_token(type, value) ->
        {%Literal{value: value}, tokens}

      _ ->
        nil
    end
  end

  defp parse_integer_literal!(tokens) do
    with nil <- maybe_parse_integer_literal(tokens) do
      throw {:expected, "integer literal", tokens}
    end
  end

  defp maybe_parse_integer_literal(tokens) do
    case tokens do
      [{:integer, value} | tokens] when is_integer(value) ->
        expr = %Literal{value: value}
        {expr, tokens}

      _ ->
        nil
    end
  end

  defp maybe_parse_parentheses(tokens) do
    case tokens do
      [{:punctuation, "("} | tokens] ->
        {expr, tokens} = parse_expression!(tokens)
        tokens = parse_punctuation!(tokens, ")")
        expr = %AST.Node.Parentheses{expr: expr}
        {expr, tokens}

      _ ->
        nil
    end
  end

  defp maybe_parse_unary_operator(tokens) do
    case tokens do
      # NOT binds looser than comparisons, IS, LIKE, IN, and BETWEEN, and tighter than
      # AND, as in standard SQL: `NOT a = b` is `NOT (a = b)`.
      [{:keyword, "NOT"} | tokens] ->
        {expr, tokens} = parse_expression!(tokens, precedence(AndOperator))
        expr = %NotOperator{right: expr}
        {expr, tokens}

      [{:punctuation, "-"} | tokens] ->
        {expr, tokens} = parse_expression!(tokens, precedence(AddOperator))
        expr = %NegativeOperator{right: expr}
        {expr, tokens}

      _ ->
        nil
    end
  end

  defp maybe_parse_mysql_interval(tokens) do
    case tokens do
      [{:keyword, "INTERVAL"} | tokens] ->
        {interval_value, tokens} = parse_mysql_interval_unit!(tokens)

        expr = %AST.Node.FunctionCall{
          name: "interval",
          args: [%Literal{value: interval_value}],
        }

        {expr, tokens}

      _ ->
        nil
    end
  end

  defp parse_mysql_interval_unit!(tokens) do
    {%Literal{value: n}, tokens} = parse_integer_literal!(tokens)

    case tokens do
      [{:keyword, "SECOND"} | tokens] ->
        {"#{n}s", tokens}

      [{:keyword, "MINUTE"} | tokens] ->
        {"#{n}m", tokens}

      [{:keyword, "HOUR"} | tokens] ->
        {"#{n}h", tokens}

      [{:keyword, "DAY"} | tokens] ->
        {"#{n}d", tokens}

      [{:keyword, "WEEK"} | tokens] ->
        {"#{n}w", tokens}

      [{:identifier, string} | _] ->
        throw {:parse_error, "Invalid interval unit: #{string}", tokens}

      [{:keyword, string} | _] ->
        throw {:parse_error, "Invalid interval unit: #{string}", tokens}

      _ ->
        throw {:parse_error, "Invalid interval unit", tokens}
    end
  end

  defp maybe_parse_splat(tokens) do
    case tokens do
      [{:punctuation, "*"} | tokens] ->
        expr = %AST.Node.Splat{}
        {expr, tokens}

      _ ->
        nil
    end
  end

  defp maybe_parse_case_expression(tokens) do
    case tokens do
      [{:keyword, "CASE"} | [{:keyword, "WHEN"} | _] = tokens] ->
        case_expr = %AST.Node.Case{case_exprs: [], when_exprs: [], then_exprs: []}
        continue_case_expression(tokens, case_expr)

      [{:keyword, "CASE"} | tokens] ->
        {expr, tokens} = parse_expression!(tokens)
        case_expr = %AST.Node.Case{case_exprs: [expr], when_exprs: [], then_exprs: []}
        continue_case_expression(tokens, case_expr)

      _ ->
        nil
    end
  end

  defp continue_expression(tokens, expr, precedence) do
    case operator(tokens) do
      {module, operator_precedence, operand_tokens} when precedence < operator_precedence ->
        {expr, tokens} = parse_operand(module, expr, operand_tokens, operator_precedence)
        continue_expression(tokens, expr, precedence)

      _ ->
        {expr, tokens}
    end
  end

  # The operator the tokens start with: {module, precedence, the tokens after it}.
  for {tokens, module, precedence} <- @operators do
    defp operator(unquote(Macro.escape(tokens)) ++ tokens) do
      {unquote(module), unquote(precedence), tokens}
    end
  end

  defp operator(_tokens) do
    nil
  end

  defp precedence(module) do
    Map.fetch!(@precedences, module)
  end

  # Builds the node for `left` followed by the operator `module`, parsing its operands at
  # the operator's own precedence, so operators of one tier associate to the left.
  defp parse_operand(BetweenOperator, left, tokens, precedence) do
    {min_expr, tokens} = parse_expression!(tokens, precedence)
    tokens = parse_keyword!(tokens, "AND")
    {max_expr, tokens} = parse_expression!(tokens, precedence)
    {%BetweenOperator{left: left, min_expr: min_expr, max_expr: max_expr}, tokens}
  end

  defp parse_operand(module, left, tokens, _precedence) when module in [Ascending, Descending] do
    {struct!(module, left: left), tokens}
  end

  defp parse_operand(module, left, tokens, precedence)
       when module in [RlikeOperator, NotRlikeOperator] do
    {right, tokens} = parse_regex!(tokens, precedence)
    {struct!(module, left: left, right: right), tokens}
  end

  defp parse_operand(module, left, tokens, precedence) do
    {right, tokens} = parse_expression!(tokens, precedence)
    {struct!(module, left: left, right: right), tokens}
  end

  defp maybe_parse_list_literal(tokens) do
    case tokens do
      [{:punctuation, "["}, {:punctuation, "]"} | tokens] ->
        expr = %ListLiteral{exprs: []}
        {expr, tokens}

      [{:punctuation, "["} | tokens] ->
        {exprs, tokens} = parse_expression_list!(tokens)
        tokens = parse_punctuation!(tokens, "]")
        expr = %ListLiteral{exprs: exprs}
        {expr, tokens}

      _ ->
        nil
    end
  end

  defp parse_regex!(tokens, precedence \\ 0) do
    tokens_at_regex = tokens
    {expr, tokens} = parse_expression!(tokens, precedence)
    validate_regex!(expr, tokens_at_regex)
    {expr, tokens}
  end

  defp validate_regex!(expr, tokens) do
    case expr do
      %Literal{value: value} when is_binary(value) ->
        try do
          Hyperscan.compile(value, 0, Hyperscan.mode("HS_MODE_BLOCK"))
        catch
          :error, :badarg ->
            throw {:parse_error, "Invalid regular expression", tokens}
        else
          {:ok, _} ->
            expr

          {:error, _} ->
            throw {:parse_error, "Invalid regular expression", tokens}
        end

      _ ->
        throw {:expected, "string literal", tokens}
    end
  end

  defp parse_punctuation!(tokens, punctuation) do
    case tokens do
      [{:punctuation, ^punctuation} | tokens] ->
        tokens

      _ ->
        throw {:expected, "punctuation: #{punctuation}", tokens}
    end
  end
end
