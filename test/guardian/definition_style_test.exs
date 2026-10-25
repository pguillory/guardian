defmodule Guardian.DefinitionStyleTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @definitions [:def, :defp, :defmacro, :defmacrop, :defn, :defnp, :deftransform, :deftransformp]

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
end
