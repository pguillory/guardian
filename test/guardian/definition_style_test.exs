defmodule Guardian.DefinitionStyleTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @definitions [:def, :defp, :defmacro, :defmacrop, :defn, :defnp, :deftransform, :deftransformp]
  @module_definitions [:defmodule, :defprotocol]

  test "source definitions use do...end blocks" do
    paths =
      @root
      |> Path.join("{lib,libtest,test}/**/*.{ex,exs}")
      |> Path.wildcard()

    assert __ENV__.file in paths, "Source scan must include this test"

    violations =
      paths
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> keyword_definitions(path)
        |> Enum.map(fn {kind, line} -> "#{Path.relative_to(path, @root)}:#{line}: #{kind}" end)
      end)

    assert violations == [],
           "Use do...end blocks for definitions:\n" <> Enum.join(violations, "\n")
  end

  test "detects public and private function and macro variants" do
    for kind <- @definitions do
      assert keyword_definitions("#{kind} sample(value), do: value") == [{kind, 1}]
      assert keyword_definitions("#{kind} sample(value) do\n  value\nend") == []
    end
  end

  test "detects multiline guarded definitions and definitions inside quotes" do
    source = ~S"""
    def sample(value \\ 1) when is_integer(value),
      do:
        value + 1

    quote do
      defp generated(value), do: value
    end
    """

    assert keyword_definitions(source) == [{:def, 1}, {:defp, 6}]
  end

  test "ignores comments, strings, declarations, variables, and keyword control flow" do
    source = ~S"""
    # def commented(value), do: value
    "def string(value), do: value"
    def declaration(value \\ 1)
    defdelegate delegated(value), to: Other
    defn = :variable
    def sample(value) do
      if(value, do: defn, else: nil)
      unless(value, do: :empty)
      case(value, do: (_ -> :ok))
    end
    """

    assert keyword_definitions(source) == []
  end

  test "compiled source files define one module each" do
    paths =
      @root
      |> Path.join("{lib,libtest}/**/*.ex")
      |> Path.wildcard()

    assert Path.join(@root, "lib/guardian/rules/step.ex") in paths,
           "Source scan must include lib/"

    assert Path.join(@root, "libtest/guardian/test/counters/client.ex") in paths,
           "Source scan must include libtest/"

    violations =
      for path <- paths,
          lines = path |> File.read!() |> module_definitions(path),
          length(lines) > 1 do
        "#{Path.relative_to(path, @root)}: lines #{Enum.join(lines, ", ")}"
      end

    assert violations == [],
           "Define one module or protocol per file:\n" <> Enum.join(violations, "\n")
  end

  test "counts nested modules and protocols but not implementations or quoted modules" do
    source = ~S"""
    # defmodule Commented do end
    defprotocol Sample.Protocol do
      def call(value)
    end

    defmodule Sample do
      @moduledoc "defmodule String do end"

      defmodule Nested do
        defstruct []
      end

      defimpl Inspect do
        defmodule HiddenInImpl do
        end

        def inspect(_value, _opts) do
          "#Sample<>"
        end
      end

      quote do
        defmodule Generated do
        end
      end
    end

    defimpl String.Chars, for: Sample do
      def to_string(_value) do
        "sample"
      end
    end
    """

    assert module_definitions(source) == [2, 6, 9, 14]
    assert module_definitions("defmodule Sample do\nend") == [1]
  end

  defp keyword_definitions(source, file \\ "nofile") do
    ast = Code.string_to_quoted!(source, token_metadata: true, file: file)

    {_ast, violations} =
      Macro.prewalk(ast, [], fn
        {kind, meta, [_head, body]} = node, violations
        when kind in @definitions and is_list(body) ->
          if Keyword.has_key?(body, :do) and not Keyword.has_key?(meta, :do) do
            {node, [{kind, meta[:line]} | violations]}
          else
            {node, violations}
          end

        node, violations ->
          {node, violations}
      end)

    Enum.reverse(violations)
  end

  # Lines of defmodule and defprotocol calls at any depth, outside quoted code.
  # defimpl blocks live with their protocol or struct and do not count, but their
  # bodies are still scanned.
  defp module_definitions(source, file \\ "nofile") do
    ast = Code.string_to_quoted!(source, file: file)

    {_ast, lines} =
      Macro.prewalk(ast, [], fn
        {:quote, _meta, _args}, lines ->
          {:quoted, lines}

        {kind, meta, [_name, _body]} = node, lines when kind in @module_definitions ->
          {node, [meta[:line] | lines]}

        node, lines ->
          {node, lines}
      end)

    Enum.reverse(lines)
  end
end
