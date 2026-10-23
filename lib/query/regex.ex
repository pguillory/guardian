defmodule Query.Regex do
  @moduledoc """
  Regular expressions for `RLIKE` and `replace()`, on Erlang's `:re` (PCRE). The
  parser validates patterns with `compile/1`, and evaluation compiles them again
  (once per evaluation, never shipped between nodes in the AST).

  - Patterns compile in UTF-8 mode without `:ucp`: subjects match by codepoint (`.`
    matches `é` whole), while `\\w`, `\\d`, `\\s`, `\\b` and POSIX classes stay
    ASCII unless the pattern starts with `(*UCP)`.
  - A subject that is not valid UTF-8 cannot be matched in UTF-8 mode; it gives nil,
    as a non-string value does.
  - Every run passes `match_limit` and `match_limit_recursion` (a depth limit under
    PCRE2), so a pattern that backtracks without end fails the query with a
    `Query.Error` instead of running on. `match_limit` counts per start position, so
    the query time limit is what bounds a value's total CPU.
  - PCRE2 keeps its backtracking frames in native memory, which the per-process heap
    limit does not see. A frame grows with the pattern's capturing groups, so memory is
    bounded by the depth limit times the group cap: at most 32 groups and a depth of
    10,000 (measured: a few MB per run, where 300 groups at depth 100,000 took about
    1.2 GB). `compile/1` enforces the cap, so the parser rejects such patterns.
  """

  @match_limit 1_000_000
  @match_limit_recursion 10_000
  @max_groups 32

  @limits [
    {:match_limit, @match_limit},
    {:match_limit_recursion, @match_limit_recursion},
    :report_errors,
  ]

  @doc "The most capturing groups a pattern may have."
  def max_groups, do: @max_groups

  @doc """
  Compiles `pattern`. Returns `{:error, :too_many_groups}` for a pattern with more
  than `max_groups/0` capturing groups, or `{:error, reason}` when `:re` rejects it.
  """
  @spec compile(String.t()) :: {:ok, :re.mp()} | {:error, term}
  def compile(pattern) when is_binary(pattern) do
    with {:ok, regex} <- :re.compile(pattern, [:unicode]) do
      if group_count(regex) > @max_groups, do: {:error, :too_many_groups}, else: {:ok, regex}
    end
  end

  # A compiled pattern is `{:re_pattern, group_count, unicode, use_crlf, program}`.
  # The format is undocumented but has not changed in many OTP releases; a change
  # fails here, loudly, rather than lifting the cap.
  defp group_count({:re_pattern, count, _, _, _}) when is_integer(count), do: count

  @doc "Whether `regex` matches anywhere in `subject`; nil for non-UTF-8 input."
  @spec matches(:re.mp(), binary) :: boolean | nil
  def matches(regex, subject) do
    case run(regex, subject, [{:capture, :none}]) do
      :invalid -> nil
      :match -> true
      :nomatch -> false
    end
  end

  @doc """
  Replaces every non-overlapping match of `regex` in `subject` with `replacement`,
  inserted literally. Matching follows PCRE: leftmost-first, and after an empty match
  the scan retries the same position for a non-empty one. Returns nil for non-UTF-8
  input. Raises `Query.Error` when the result would exceed the string limit
  or a match would split a UTF-8 character (`\\C`).
  """
  @spec replace(:re.mp(), binary, binary) :: binary | nil
  def replace(regex, subject, replacement) do
    case run(regex, subject, [:global, {:capture, :first, :index}]) do
      :invalid ->
        nil

      :nomatch ->
        subject

      {:match, matches} ->
        spans = Enum.map(matches, fn [span] -> span end)
        check_boundaries!(subject, spans)

        matched = Enum.reduce(spans, 0, fn {_start, length}, sum -> sum + length end)
        size = byte_size(subject) - matched + length(spans) * byte_size(replacement)
        Query.Limits.check_string_size!("replace", size)

        splice(subject, spans, replacement, 0, [])
    end
  end

  # The rescue covers only this call: `:re.run/3` raises badarg for a subject that is
  # not valid UTF-8 against a UTF-8 pattern. Anything else raising here is a bug and
  # is raised again.
  defp run(regex, subject, options) do
    result =
      try do
        :re.run(subject, regex, options ++ @limits)
      rescue
        error in ArgumentError ->
          if String.valid?(subject), do: reraise(error, __STACKTRACE__), else: :invalid
      end

    case result do
      {:error, limit} when limit in [:match_limit, :match_limit_recursion] ->
        raise Query.Error,
          message:
            "regular expression too complex: it exceeded the backtracking limit on a " <>
              "value; simplify the pattern, for example by removing nested quantifiers"

      result ->
        result
    end
  end

  defp check_boundaries!(subject, spans) do
    Enum.each(spans, fn {start, length} ->
      unless boundary?(subject, start) and boundary?(subject, start + length) do
        raise Query.Error,
          message:
            "regular expression matched part of a character; \\C is not supported " <>
              "in replace()"
      end
    end)
  end

  # A UTF-8 character boundary: the end of the subject, or any byte that is not a
  # continuation byte (0b10xxxxxx).
  defp boundary?(subject, offset) when offset == byte_size(subject), do: true

  defp boundary?(subject, offset) do
    Bitwise.band(:binary.at(subject, offset), 0xC0) != 0x80
  end

  defp splice(subject, [], _replacement, position, acc) do
    tail = binary_part(subject, position, byte_size(subject) - position)
    IO.iodata_to_binary(Enum.reverse([tail | acc]))
  end

  defp splice(subject, [{start, length} | spans], replacement, position, acc) do
    before = binary_part(subject, position, start - position)
    splice(subject, spans, replacement, start + length, [replacement, before | acc])
  end
end
