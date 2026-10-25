defmodule Guardian.NamespaceTest do
  use ExUnit.Case, async: true

  test "application modules belong to Guardian, including external protocol implementations" do
    modules = Application.spec(:guardian, :modules)
    assert is_list(modules) and modules != []

    external_implementations = [
      Enumerable.Guardian.Query.DistributedStream,
      Inspect.Guardian.ObjectStore.S3,
    ]

    for module <- modules do
      assert String.starts_with?(Atom.to_string(module), "Elixir.Guardian.") or
               guardian_protocol_implementation?(module),
             "module outside Guardian namespace: #{inspect(module)}"
    end

    for module <- external_implementations, do: assert(module in modules)
    assert Guardian.Rules.Compiler.name(0) == Guardian.Rules.Compiled.M0
  end

  defp guardian_protocol_implementation?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__impl__, 1) and
      String.starts_with?(Atom.to_string(module.__impl__(:for)), "Elixir.Guardian.") and
      module == Module.concat(module.__impl__(:protocol), module.__impl__(:for))
  end
end
