defmodule Guardian.AST.Tokenizer do
  alias Guardian.AST.ParseError

  @whitespace [?\s, ?\n, ?\r, ?\t]
  @digits ?0..?9
  @max_int64 9_223_372_036_854_775_807
  @max_int64_digits @max_int64 |> Integer.to_string() |> byte_size()
  @ident_characters Enum.concat([?0..?9, ?a..?z, ?A..?Z, [?_]])
  @keywords ~w[
    AND
    AS
    ASC
    BETWEEN
    BY
    CASE
    DAY
    DELETE
    DESC
    DESCRIBE
    ELSE
    END
    FROM
    GROUP
    HAVING
    HOUR
    ILIKE
    IN
    INSERT
    INTERVAL
    INTO
    IS
    LET
    LIKE
    LIMIT
    MINUTE
    NOT
    OR
    ORDER
    RLIKE
    SECOND
    SELECT
    SHOW
    TABLES
    THEN
    VALUES
    WEEK
    WHEN
    WHERE
  ]
  @punctuation ~w{< <= > >= <=> = != ( ) + - * / , ; || [ ]}

  def keywords do
    @keywords
  end

  def punctuation do
    @punctuation
  end

  def truncate_after_semicolon(source) do
    truncate_after_semicolon(source, 0, 0)
  end

  def truncate_after_semicolon(source, row, col) do
    tokens = tokenize_raw(source)
    {tokens_before_reversed, tokens_after} = split_tokens_at_row_col(tokens, row, col)
    tokens_after = Enum.take_while(tokens_after, &(not match?({:punctuation, ";"}, &1)))
    tokens = Enum.reverse(tokens_before_reversed, tokens_after)

    tokens
    |> Enum.map(fn {_type, raw_token} -> raw_token end)
    |> Enum.join()
  end

  defp split_tokens_at_row_col(tokens, target_row, target_col) do
    split_tokens_at_row_col(tokens, [], target_row, target_col, 0, 0)
  end

  defp split_tokens_at_row_col(tokens, acc, target_row, target_col, row, col)
       when row > target_row or (row == target_row and col >= target_col) do
    with [{:whitespace, _} | _] <- tokens,
         [{:punctuation, ";"} | acc] <- acc do
      {acc, []}
    else
      _ ->
        {acc, tokens}
    end
  end

  defp split_tokens_at_row_col([], acc, _target_row, _target_col, _row, _col) do
    {acc, []}
  end

  defp split_tokens_at_row_col(
         [{_type, raw_token} = token | tokens],
         acc,
         target_row,
         target_col,
         row,
         col
       ) do
    {row, col} = end_position(raw_token, row, col)
    split_tokens_at_row_col(tokens, [token | acc], target_row, target_col, row, col)
  end

  def position(source, remaining_tokens) do
    tokenize_raw(source)
    |> Enum.reverse()
    |> consumed_raw_tokens_reverse(Enum.reverse(remaining_tokens))
    |> Enum.map(fn {_type, raw_token} -> raw_token end)
    |> Enum.reverse()
    |> Enum.join()
    |> end_position()
  end

  @doc """
  The 0-based row each token of `tokenize/1`'s result starts on, as a tuple indexed
  like that list.
  """
  def token_rows(source) do
    {rows, _row} =
      tokenize_raw(source)
      |> Enum.reduce({[], 0}, fn {type, raw_token}, {rows, row} ->
        rows = if type in [:whitespace, :comment], do: rows, else: [row | rows]
        {rows, row + count_newlines(raw_token)}
      end)

    rows |> Enum.reverse() |> List.to_tuple()
  end

  defp count_newlines(text) do
    length(:binary.matches(text, "\n"))
  end

  # The source text of the first remaining token, as written, or nil at end of input.
  def next_raw_token(_source, []) do
    nil
  end

  def next_raw_token(source, remaining_tokens) do
    {_type, raw_token} =
      tokenize_raw(source)
      |> Enum.reject(fn {type, _raw_token} -> type in [:whitespace, :comment] end)
      |> Enum.at(-length(remaining_tokens))

    raw_token
  end

  defp consumed_raw_tokens_reverse(raw_tokens, []) do
    raw_tokens
  end

  defp consumed_raw_tokens_reverse([{type, _raw_token} | raw_tokens], remaining_tokens)
       when type in [:whitespace, :comment] do
    consumed_raw_tokens_reverse(raw_tokens, remaining_tokens)
  end

  defp consumed_raw_tokens_reverse([{type, _raw_token} | raw_tokens], [
         {type, _value} | remaining_tokens,
       ]) do
    consumed_raw_tokens_reverse(raw_tokens, remaining_tokens)
  end

  defp end_position(consumed_source) do
    end_position(consumed_source, 0, 0)
  end

  defp end_position(<<?\n, rest::binary>>, row, _col) do
    end_position(rest, row + 1, 0)
  end

  defp end_position(<<_, rest::binary>>, row, col) do
    end_position(rest, row, col + 1)
  end

  defp end_position(<<>>, row, col) do
    {row, col}
  end

  @doc """
  The tokens of `source`: `{type, value}` pairs with whitespace and comments dropped,
  keywords upcased, identifiers downcased, and literals evaluated. Raises
  `Guardian.AST.ParseError` at the first error, scanning errors before evaluation errors.
  """
  def tokenize(source) do
    case evaluate(tokenize_raw(source), 0, []) do
      {:ok, tokens} -> tokens
      {:error, reason, offset} -> raise_at(source, reason, offset)
    end
  end

  @doc """
  The raw tokens of `source`: `{type, text}` pairs whose texts concatenate back to
  `source`, whitespace and comments included. Raises `Guardian.AST.ParseError` where `source`
  cannot be scanned.
  """
  def tokenize_raw(source) do
    case scan(source, source, []) do
      {:ok, raw_tokens} -> raw_tokens
      {:error, reason, offset} -> raise_at(source, reason, offset)
    end
  end

  defp raise_at(source, reason, offset) do
    {row, col} = source |> binary_part(0, offset) |> end_position()
    raise ParseError, reason: reason, row: row, col: col
  end

  # `offset` is the byte offset in the source of the token at the head of the list.
  defp evaluate([], _offset, acc) do
    {:ok, Enum.reverse(acc)}
  end

  defp evaluate([{type, raw_token} | raw_tokens], offset, acc) do
    next_offset = offset + byte_size(raw_token)

    case evaluate_token(type, raw_token) do
      {:ok, token} -> evaluate(raw_tokens, next_offset, [token | acc])
      :skip -> evaluate(raw_tokens, next_offset, acc)
      {:error, reason, token_offset} -> {:error, reason, offset + token_offset}
    end
  end

  defp evaluate_token(:null, _raw_token) do
    {:ok, {:null, nil}}
  end

  defp evaluate_token(false, _raw_token) do
    {:ok, {false, false}}
  end

  defp evaluate_token(true, _raw_token) do
    {:ok, {true, true}}
  end

  defp evaluate_token(:integer, raw_token) do
    case evaluate_integer(raw_token) do
      {:ok, integer} -> {:ok, {:integer, integer}}
      :error -> {:error, "Number out of range", 0}
    end
  end

  defp evaluate_token(:float, raw_token) do
    case evaluate_float(raw_token) do
      {:ok, float} -> {:ok, {:float, float}}
      :error -> {:error, "Number out of range", 0}
    end
  end

  defp evaluate_token(:string, raw_token) do
    with {:ok, string} <- Guardian.AST.StringEncoding.decode_string(raw_token) do
      {:ok, {:string, string}}
    end
  end

  defp evaluate_token(:keyword, raw_token) do
    {:ok, {:keyword, String.upcase(raw_token)}}
  end

  defp evaluate_token(:identifier, raw_token) do
    {:ok, {:identifier, String.downcase(raw_token)}}
  end

  defp evaluate_token(:punctuation, raw_token) do
    {:ok, {:punctuation, raw_token}}
  end

  defp evaluate_token(type, _raw_token) when type in [:comment, :whitespace] do
    :skip
  end

  # Integer literals are unsigned (minus is an operator) and must fit in int64, so they
  # run from 0 to 9223372036854775807; the smallest int64 is `-9223372036854775807 - 1`.
  # Leading zeros are skipped and the significant digits counted before converting, so
  # a huge literal is `:error` without building a bignum.
  defp evaluate_integer(source) do
    digits = skip_leading_zeros(source)

    cond do
      digits == "" ->
        {:ok, 0}

      byte_size(digits) > @max_int64_digits ->
        :error

      true ->
        integer = String.to_integer(digits)
        if integer <= @max_int64, do: {:ok, integer}, else: :error
    end
  end

  defp skip_leading_zeros(<<?0, rest::binary>>) do
    skip_leading_zeros(rest)
  end

  defp skip_leading_zeros(source) do
    source
  end

  # `1.` is the float 1.0 and `1e5` the float 100000.0, as in standard SQL.
  # String.to_float needs digits on both sides of a dot, so the mantissa is completed
  # before the exponent (`1.e5` reads as `1.0e5`, `1e5` as `1.0e5`). A float too large
  # to represent (`1e400`) is `:error`, a parse error at the number.
  defp evaluate_float(source) do
    {mantissa, exponent} =
      case :binary.match(source, ["e", "E"]) do
        {at, _} -> String.split_at(source, at)
        :nomatch -> {source, ""}
      end

    mantissa =
      cond do
        String.ends_with?(mantissa, ".") -> mantissa <> "0"
        String.contains?(mantissa, ".") -> mantissa
        true -> mantissa <> ".0"
      end

    {:ok, String.to_float(mantissa <> exponent)}
  rescue
    ArgumentError -> :error
  end

  # `rest` is what remains of `full_source` to scan. Errors carry the byte offset in
  # `full_source` where they are reported.
  defp scan(<<>>, _full_source, acc) do
    {:ok, Enum.reverse(acc)}
  end

  defp scan(rest, full_source, acc) do
    case next_token(rest) do
      {:ok, type, after_token} ->
        scan(after_token, full_source, [{type, take_prefix(rest, after_token)} | acc])

      {:error, reason, at} ->
        {:error, reason, byte_size(full_source) - byte_size(at)}
    end
  end

  # The type of the token at the start of `source` and the source after it, or an
  # error with the source where it is reported.
  defp next_token(source) do
    case source do
      <<c, rest::binary>> when c in @whitespace ->
        {:ok, :whitespace, skip_whitespace(rest)}

      <<?-, ?-, rest::binary>> ->
        {:ok, :comment, skip_comment(rest)}

      <<c, rest::binary>> when c in @digits ->
        integer(rest)

      <<c, rest::binary>> when c in @ident_characters ->
        ident(rest, source)

      <<?', rest::binary>> ->
        string(rest, source)

      <<value::binary-size(3), rest::binary>> when value in @punctuation ->
        {:ok, :punctuation, rest}

      <<value::binary-size(2), rest::binary>> when value in @punctuation ->
        {:ok, :punctuation, rest}

      <<value::binary-size(1), rest::binary>> when value in @punctuation ->
        {:ok, :punctuation, rest}

      _ ->
        {:error, "Unexpected character", source}
    end
  end

  defp skip_whitespace(<<c, rest::binary>>) when c in @whitespace do
    skip_whitespace(rest)
  end

  defp skip_whitespace(source) do
    source
  end

  # A comment runs to the end of the line, newline included.
  defp skip_comment(<<?\n, rest::binary>>) do
    rest
  end

  defp skip_comment(<<_, rest::binary>>) do
    skip_comment(rest)
  end

  defp skip_comment(<<>>) do
    <<>>
  end

  defp integer(source) do
    case source do
      <<c, rest::binary>> when c in @digits ->
        integer(rest)

      <<?., rest::binary>> ->
        float(rest)

      _ ->
        case exponent(source) do
          {:ok, rest} -> {:ok, :float, rest}
          :error -> {:ok, :integer, source}
        end
    end
  end

  defp float(source) do
    case source do
      <<c, rest::binary>> when c in @digits ->
        float(rest)

      _ ->
        case exponent(source) do
          {:ok, rest} -> {:ok, :float, rest}
          :error -> {:ok, :float, source}
        end
    end
  end

  # A number's exponent, as in standard SQL: `e` or `E`, an optional sign, and at least
  # one digit (`1e20`, `1.5E-3`). Returns the source after it, or `:error` if there is
  # none, so `1e`, `1e+` and `1end` tokenize as a number followed by something else.
  defp exponent(<<e, rest::binary>>) when e in [?e, ?E] do
    unsigned =
      case rest do
        <<sign, unsigned::binary>> when sign in [?+, ?-] -> unsigned
        _ -> rest
      end

    case unsigned do
      <<c, _::binary>> when c in @digits -> {:ok, skip_digits(unsigned)}
      _ -> :error
    end
  end

  defp exponent(_source) do
    :error
  end

  defp skip_digits(<<c, rest::binary>>) when c in @digits do
    skip_digits(rest)
  end

  defp skip_digits(source) do
    source
  end

  # A dotted path such as `user.name` or `users..name` is one identifier token, spelled
  # exactly like the stored column name for that nested field. Each run of N dots marks
  # N - 1 list boundaries.
  defp ident(source, start) do
    case source do
      <<c, rest::binary>> when c in @ident_characters ->
        ident(rest, start)

      <<?., _::binary>> ->
        case skip_dots(source) do
          <<c, _::binary>> = rest when c in @ident_characters ->
            ident(rest, start)

          _ ->
            finish_ident(source, start)
        end

      _ ->
        finish_ident(source, start)
    end
  end

  defp finish_ident(source, start) do
    type =
      case String.upcase(take_prefix(start, source)) do
        "NULL" -> :null
        "FALSE" -> false
        "TRUE" -> true
        keyword when keyword in @keywords -> :keyword
        _ -> :identifier
      end

    {:ok, type, source}
  end

  defp skip_dots(<<?., rest::binary>>) do
    skip_dots(rest)
  end

  defp skip_dots(source) do
    source
  end

  # A backslash escapes the next byte, so `\'` and `\\` never end the literal.
  # Guardian.AST.StringEncoding decides whether the escape is valid.
  defp string(source, start) do
    case source do
      <<?\\, _, rest::binary>> ->
        string(rest, start)

      <<?', rest::binary>> ->
        {:ok, :string, rest}

      <<_, rest::binary>> ->
        string(rest, start)

      <<>> ->
        {:error, "Unterminated string literal", start}
    end
  end

  # `suffix` is always a suffix of `string` here, so only its size matters (a match
  # on the suffix's bytes would make scanning quadratic).
  defp take_prefix(string, suffix) do
    binary_part(string, 0, byte_size(string) - byte_size(suffix))
  end
end
