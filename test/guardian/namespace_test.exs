defmodule Guardian.NamespaceTest do
  use ExUnit.Case, async: true

  test "application modules belong to Guardian, including external protocol implementations" do
    modules = Application.spec(:guardian, :modules)
    assert is_list(modules) and modules != []

    external_implementations = [
      Enumerable.Guardian.Query.DistributedStream,
      Inspect.Guardian.Rules.Store.S3,
    ]

    for module <- modules do
      assert String.starts_with?(Atom.to_string(module), "Elixir.Guardian.") or
               module in external_implementations,
             "module outside Guardian namespace: #{inspect(module)}"
    end

    for module <- external_implementations, do: assert(module in modules)
    assert Guardian.Rules.Compiler.name(0) == Guardian.Rules.Compiled.M0
  end
end
