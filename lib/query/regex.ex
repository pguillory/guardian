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

  # A subject this size has at most about 33,000 matches (10 to 20 MB of process
  # memory at worst, measured), so it
  # is replaced in the calling process; a larger one goes to a capped helper, with the
  # query heap limit as its cap, or this many MiB when that is off.
  @inline_max_bytes 16 * 1024
  @helper_heap_mb 256

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
  input. Raises `Query.Error` when the result would exceed the string limit, a match
  would split a UTF-8 character (`\\C`), or a value has too many matches.

  `:re` returns every match of a value at once, as a list on the calling process's
  heap, and a value can have about two matches per character (`(?:|a)` matches 2n + 1 times in n characters). A
  subject over #{@inline_max_bytes} bytes is therefore replaced in a helper process
  whose own heap is capped (`helper_heap_mb/0`) even when the query heap limit is off,
  so one value's matches cannot take more than that; a value that needs more fails the
  query.
  """
  @spec replace(:re.mp(), binary, binary) :: binary | nil
  def replace(regex, subject, replacement) when byte_size(subject) <= @inline_max_bytes do
    replace_inline(regex, subject, replacement)
  end

  def replace(regex, subject, replacement) do
    replace_in_helper(regex, subject, replacement)
  end

  @doc """
  The heap cap in MiB of the process that replaces in a large value: the query heap
  limit (`Query.Limits.max_heap_mb/0`), or #{@helper_heap_mb} when that is off.
  """
  def helper_heap_mb do
    case Query.Limits.max_heap_mb() do
      mb when is_integer(mb) and mb > 0 -> mb
      _ -> @helper_heap_mb
    end
  end

  defp replace_inline(regex, subject, replacement) do
    case run(regex, subject, [:global, {:capture, :first, :index}]) do
      :invalid ->
        nil

      :nomatch ->
        subject

      {:match, matches} ->
        {count, matched} = measure!(subject, matches, 0, 0)
        size = byte_size(subject) - matched + count * byte_size(replacement)
        Query.Limits.check_string_size!("replace", size)

        splice(subject, matches, replacement, 0, <<>>)
    end
  end

  # Runs replace_inline/3 in a process with its own heap cap and returns its result,
  # raising whatever it raised. The helper is not linked to the caller: a link would
  # carry the helper's heap kill (`killed`) to the caller. Instead the helper's first
  # act is to start a watcher that kills it if the caller dies (a query stopped at its
  # time limit), so no helper outlives its caller, even one that dies at once.
  defp replace_in_helper(regex, subject, replacement) do
    caller = self()
    heap_mb = helper_heap_mb()
    words = div(heap_mb * 1024 * 1024, :erlang.system_info(:wordsize))

    {helper, monitor} =
      :erlang.spawn_opt(
        fn ->
          watch(caller, self())

          result =
            try do
              {:ok, replace_inline(regex, subject, replacement)}
            catch
              kind, reason -> {:raise, kind, reason, __STACKTRACE__}
            end

          send(caller, {__MODULE__, self(), result})
        end,
        [
          :monitor,
          {:max_heap_size,
           %{size: words, kill: true, error_logger: false, include_shared_binaries: false}},
        ]
      )

    receive do
      {__MODULE__, ^helper, result} ->
        Process.demonitor(monitor, [:flush])

        case result do
          {:ok, value} -> value
          {:raise, kind, reason, stacktrace} -> :erlang.raise(kind, reason, stacktrace)
        end

      # Only the heap cap kills a helper whose caller is alive (its watcher kills it
      # only once the caller is gone), so `:killed` is taken to be the cap.
      {:DOWN, ^monitor, :process, ^helper, :killed} ->
        raise Query.Error,
          message:
            "regular expression matched too many times in one value: replace() " <>
              "keeps every match of a value, and one value's matches took over " <>
              "#{heap_mb} MiB (GUARDIAN_QUERY_MAX_HEAP_MB, or #{@helper_heap_mb} when " <>
              "that is 0); use a pattern that matches less often, for example one " <>
              "that cannot match the empty string"

      {:DOWN, ^monitor, :process, ^helper, reason} ->
        exit({:replace_helper, reason})
    end
  end

  # Monitors taken on a process that is already gone report it down at once, so the
  # watcher acts even if the caller died before it started.
  defp watch(caller, helper) do
    spawn(fn ->
      caller_monitor = Process.monitor(caller)
      helper_monitor = Process.monitor(helper)

      receive do
        {:DOWN, ^caller_monitor, _, _, _} -> Process.exit(helper, :kill)
        {:DOWN, ^helper_monitor, _, _, _} -> :ok
      end
    end)
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

  # Checks that every match starts and ends on a character boundary, and returns the
  # match count and the bytes matched, in one pass over the `:re` result.
  defp measure!(_subject, [], count, matched), do: {count, matched}

  defp measure!(subject, [[{start, length}] | matches], count, matched) do
    unless boundary?(subject, start) and boundary?(subject, start + length) do
      raise Query.Error,
        message:
          "regular expression matched part of a character; \\C is not supported " <>
            "in replace()"
    end

    measure!(subject, matches, count + 1, matched + length)
  end

  # A UTF-8 character boundary: the end of the subject, or any byte that is not a
  # continuation byte (0b10xxxxxx).
  defp boundary?(subject, offset) when offset == byte_size(subject), do: true

  defp boundary?(subject, offset) do
    Bitwise.band(:binary.at(subject, offset), 0xC0) != 0x80
  end

  # Appends to one binary, which the VM grows in place, rather than collecting a list of
  # slices: the result lives outside the process heap, and the heap holds only the
  # matches.
  defp splice(subject, [], _replacement, position, acc) do
    acc <> binary_part(subject, position, byte_size(subject) - position)
  end

  defp splice(subject, [[{start, length}] | matches], replacement, position, acc) do
    acc = acc <> binary_part(subject, position, start - position) <> replacement
    splice(subject, matches, replacement, start + length, acc)
  end
end
