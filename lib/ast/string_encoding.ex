defmodule AST.StringEncoding do
  @moduledoc """
  SQL string literals: single-quoted, with the backslash escapes `\\'`, `\\\\`, `\\/`,
  `\\b`, `\\f`, `\\n`, `\\r`, `\\t` and `\\uXXXX` (UTF-16, surrogate pairs as in JSON).
  `decode_string/1` reads one and `encode_string/1` writes one back.
  """

  @doc """
  Decodes a string literal token, quotes included.

  Returns `{:ok, string}` or `{:error, reason, offset}`, where `offset` is the byte
  offset in the literal of the bad escape's backslash (for a high surrogate without a
  valid low one, the high surrogate's), or 0 when the decoded string is not valid
  UTF-8. Source bytes are copied verbatim, so that check comes after decoding; an
  invalid string would also crash `encode_string/1`, which unparses column labels.
  """
  @spec decode_string(binary()) :: {:ok, String.t()} | {:error, String.t(), non_neg_integer()}
  def decode_string(literal) do
    <<?', inner::binary-size(byte_size(literal) - 2), ?'>> = literal

    case decode(inner, inner, "") do
      {:ok, string} ->
        if String.valid?(string),
          do: {:ok, string},
          else: {:error, "Invalid UTF-8 in string literal", 0}

      # Offsets within `inner` are one less than in the quoted literal.
      {:error, reason, offset} ->
        {:error, reason, offset + 1}
    end
  end

  @escapes %{
    ?' => "'",
    ?\\ => "\\",
    ?/ => "/",
    ?b => "\b",
    ?f => "\f",
    ?n => "\n",
    ?r => "\r",
    ?t => "\t",
  }

  defp decode(<<?\\, c, rest::binary>>, inner, acc) when is_map_key(@escapes, c) do
    decode(rest, inner, acc <> @escapes[c])
  end

  defp decode(<<?\\, ?u, hex::binary-size(4), rest::binary>> = escape, inner, acc) do
    offset = byte_size(inner) - byte_size(escape)

    with {:hex, {:ok, unit}} <- {:hex, hex_unit(hex)},
         {:ok, codepoint, rest} <- codepoint(unit, rest) do
      decode(rest, inner, <<acc::binary, codepoint::utf8>>)
    else
      {:hex, :error} -> {:error, "Invalid \\u escape", offset}
      {:error, reason} -> {:error, reason, offset}
    end
  end

  defp decode(<<?\\, _::binary>> = escape, inner, _acc) do
    {:error, "Bad escaped character", byte_size(inner) - byte_size(escape)}
  end

  defp decode(<<c, rest::binary>>, inner, acc), do: decode(rest, inner, <<acc::binary, c>>)
  defp decode(<<>>, _inner, acc), do: {:ok, acc}

  # A high surrogate must be followed by a \u low surrogate; together they are one
  # codepoint, as in JSON.
  defp codepoint(high, rest) when high in 0xD800..0xDBFF do
    with <<?\\, ?u, hex::binary-size(4), rest::binary>> <- rest,
         {:ok, low} when low in 0xDC00..0xDFFF <- hex_unit(hex) do
      {:ok, 0x10000 + (high - 0xD800) * 0x400 + (low - 0xDC00), rest}
    else
      _ -> {:error, "Invalid UTF-16 codepoint"}
    end
  end

  defp codepoint(low, _rest) when low in 0xDC00..0xDFFF, do: {:error, "Invalid UTF-16 codepoint"}
  defp codepoint(unit, rest), do: {:ok, unit, rest}

  defguardp is_hex(c) when c in ?0..?9 or c in ?a..?f or c in ?A..?F

  # The four hex digits of a \u escape (https://www.rfc-editor.org/rfc/rfc8259).
  # Integer.parse/2 alone would also take a sign, as in `\u+123`.
  defp hex_unit(<<a, b, c, d>> = hex)
       when is_hex(a) and is_hex(b) and is_hex(c) and is_hex(d) do
    {:ok, String.to_integer(hex, 16)}
  end

  defp hex_unit(_hex), do: :error

  @printable AST.Unicode.codepoint("U+0020")..AST.Unicode.codepoint("U+10FFFF")

  @doc """
  Writes `value`, a valid UTF-8 string, as a string literal that `decode_string/1`
  reads back. Quote, backslash and slash are escaped; other characters from U+0020 up
  are written as they are, and control characters as their short escape or `\\u`
  with four lowercase hex digits.
  """
  @spec encode_string(String.t()) :: String.t()
  def encode_string(value) do
    "'" <> encode(value) <> "'"
  end

  defp encode(value) do
    String.codepoints(value)
    |> Enum.map_join(fn
      ~s['] -> ~S[\']
      ~s[\\] -> ~s[\\\\]
      ~s[/] -> ~S[\/]
      ~s[\b] -> ~S[\b]
      ~s[\f] -> ~S[\f]
      ~s[\n] -> ~S[\n]
      ~s[\r] -> ~S[\r]
      ~s[\t] -> ~S[\t]
      <<codepoint::utf8>> when codepoint in @printable -> <<codepoint::utf8>>
      <<codepoint::utf8>> -> ~S[\u] <> hex4(codepoint)
    end)
  end

  # Only codepoints below U+0020 get here, so one UTF-16 unit.
  defp hex4(codepoint) do
    codepoint |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0")
  end
end
