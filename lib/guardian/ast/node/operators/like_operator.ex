defmodule Guardian.AST.Node.Operators.LikeOperator do
  use Guardian.AST.Node.BinaryOperator, symbol: "LIKE"

  alias Guardian.Query.ColumnOrConstant
  alias Guardian.Query.Constant

  # The most pattern characters (not counting `%`) LIKE accepts; a longer pattern
  # matches nothing (null). It bounds the state machine below to a few machine words.
  @max_pattern_items 1_000

  def max_pattern_items do
    @max_pattern_items
  end

  defimpl Guardian.Query.Eval do
    def eval(%@for{left: left, right: right}, context) do
      column1 = Guardian.Query.Eval.eval(left, context)

      case Guardian.Query.Eval.eval(right, context) do
        # A constant pattern, the usual case, is compiled once rather than per row.
        %Constant{value: pattern} ->
          compiled = @for.compile_constant(pattern)
          ColumnOrConstant.map(column1, &@for.match(&1, compiled))

        column2 ->
          ColumnOrConstant.map(column1, column2, &@for.eval/2)
      end
    end
  end

  @doc """
  Whether `value` matches `pattern`: `%` matches any run of characters, `_` exactly
  one, anything else itself. Null unless both are strings, and for a pattern of more
  than #{@max_pattern_items} characters besides `%`. Characters are UTF-8 code points
  when both strings are valid UTF-8, and bytes otherwise.

  The pattern runs as a state machine over the value, one character at a time, with
  the set of live states held as the bits of one integer (shift-and): state `i`
  means the first `i` non-`%` pattern items have matched. There is no backtracking,
  and with the pattern bounded, time is linear in the value's length.
  """
  def eval(value, pattern) when is_binary(value) and is_binary(pattern) do
    unit = unit(value, pattern)
    run(value, unit, compile(pattern, unit))
  end

  def eval(_value, _pattern) do
    nil
  end

  @doc false
  # For a constant pattern, compiled once: its UTF-8 form (nil if it isn't valid
  # UTF-8) and its byte form; each value then picks one.
  def compile_constant(pattern) do
    {compile(pattern, :utf8), compile(pattern, :byte)}
  end

  @doc false
  def match(value, {utf8, bytes}) when is_binary(value) do
    if utf8 != nil and String.valid?(value),
      do: run(value, :utf8, utf8),
      else: run(value, :byte, bytes)
  end

  def match(_value, _compiled) do
    nil
  end

  defp unit(value, pattern) do
    if(String.valid?(value) and String.valid?(pattern), do: :utf8, else: :byte)
  end

  defp run(_value, _unit, nil) do
    nil
  end

  defp run(value, unit, {masks, any, loops, accept}) do
    run(value, unit, masks, any, loops, accept, 1)
  end

  @doc false
  # `{masks, any, loops, accept}`, or nil for a non-string, a too-long pattern, or
  # (for :utf8) a pattern that isn't valid UTF-8. masks: character => the states it
  # advances into (bit i + 1 for item i); any: the states `_` advances into; loops:
  # the states a `%` keeps live on any character; accept: the final state.
  def compile(pattern, unit) when is_binary(pattern) do
    if unit == :byte or String.valid?(pattern), do: compile(pattern, unit, 0, %{}, 0, 0)
  end

  def compile(_pattern, _unit) do
    nil
  end

  defp compile(_pattern, _unit, i, _masks, _any, _loops) when i > @max_pattern_items do
    nil
  end

  defp compile(<<>>, _unit, i, masks, any, loops) do
    {masks, any, loops, Bitwise.bsl(1, i)}
  end

  defp compile(<<"%", rest::binary>>, unit, i, masks, any, loops) do
    compile(rest, unit, i, masks, any, Bitwise.bor(loops, Bitwise.bsl(1, i)))
  end

  defp compile(<<"_", rest::binary>>, unit, i, masks, any, loops) do
    compile(rest, unit, i + 1, masks, Bitwise.bor(any, Bitwise.bsl(1, i + 1)), loops)
  end

  defp compile(pattern, unit, i, masks, any, loops) do
    {char, rest} = next(pattern, unit)
    bit = Bitwise.bsl(1, i + 1)
    masks = Map.update(masks, char, bit, &Bitwise.bor(&1, bit))
    compile(rest, unit, i + 1, masks, any, loops)
  end

  defp run(_value, _unit, _masks, _any, _loops, _accept, 0) do
    false
  end

  defp run(<<>>, _unit, _masks, _any, _loops, accept, states) do
    Bitwise.band(states, accept) != 0
  end

  defp run(value, unit, masks, any, loops, accept, states) do
    {char, rest} = next(value, unit)
    step = Bitwise.bor(any, Map.get(masks, char, 0))
    advanced = Bitwise.band(Bitwise.bsl(states, 1), step)
    states = Bitwise.bor(advanced, Bitwise.band(states, loops))
    run(rest, unit, masks, any, loops, accept, states)
  end

  defp next(<<char::utf8, rest::binary>>, :utf8) do
    {char, rest}
  end

  defp next(<<byte, rest::binary>>, :byte) do
    {byte, rest}
  end
end
