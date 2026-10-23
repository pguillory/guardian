defmodule AST.Unicode do
  @moduledoc """
  Code points named as `"U+XXXX"`, for `AST.StringEncoding`'s compile-time ranges and
  for tests.
  """

  def codepoint("U+" <> <<hex::binary>>) when rem(byte_size(hex), 2) == 0 do
    case Base.decode16!(hex) do
      <<value::unsigned-8>> -> value
      <<value::unsigned-16>> -> value
      <<value::unsigned-24>> -> value
      <<value::unsigned-32>> -> value
      <<value::unsigned-40>> -> value
      <<value::unsigned-48>> -> value
      <<value::unsigned-56>> -> value
      <<value::unsigned-64>> -> value
    end
  end

  def codepoint("U+" <> <<hex::binary>>) when rem(byte_size(hex), 2) == 1 do
    codepoint("U+0" <> <<hex::binary>>)
  end

  def utf8(name) do
    <<codepoint(name)::utf8>>
  end
end
