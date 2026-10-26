defmodule Guardian.Storage.Column.NIFTest do
  use ExUnit.Case, async: true

  alias Guardian.Storage.Column.NIF

  @column_c Path.expand("../../../../src/column.c", __DIR__)

  test "the stubs match nif_funcs[] in src/column.c by name and arity" do
    c_funcs = c_nif_funcs(File.read!(@column_c))

    assert c_funcs != []
    assert c_funcs == Enum.uniq(c_funcs)
    assert Enum.sort(NIF.__info__(:functions) -- [init: 0]) == Enum.sort(c_funcs)
  end

  defp c_nif_funcs(source) do
    block =
      case Regex.run(~r/ErlNifFunc\s+nif_funcs\[\]\s*=\s*\{(.*?)\n\};/s, source) do
        [_, block] -> block
        nil -> flunk("no nif_funcs[] table in #{@column_c}")
      end

    block
    |> String.replace(~r{/\*.*?\*/}s, "")
    |> String.replace(~r{//[^\n]*}, "")
    |> then(&Regex.scan(~r/\{\s*"(\w+)"\s*,\s*(\d+)\s*,\s*\w+/, &1))
    |> Enum.map(fn [_, name, arity] -> {String.to_atom(name), String.to_integer(arity)} end)
  end
end
