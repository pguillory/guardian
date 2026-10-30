defmodule Guardian.FormatterTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  setup_all do
    # Warm dev dependencies before collecting only the formatted stdout from stdin.
    assert_success(
      System.cmd("mix", ["deps.loadpaths"],
        cd: @root,
        env: [{"MIX_ENV", "dev"}],
        stderr_to_stdout: true
      )
    )

    :ok
  end

  setup do
    directory =
      Path.join(System.tmp_dir!(), "guardian-formatter-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    path = Path.join(directory, "repro.exs")
    source = "value=%{outer: %URI{path: [\"#{String.duplicate("x", 90)}\"]}}\n"
    File.write!(path, source)
    %{path: path, source: source}
  end

  test "one format invocation converges on newly wrapped literals", %{path: path} do
    assert_success(format([path]))
    formatted = File.read!(path)
    assert formatted =~ ~s(#{String.duplicate("x", 90)}",\n)
    assert formatted =~ "    ],\n  },\n}"
    assert_success(format(["--check-formatted", path]))
    assert_success(format([path]))
    assert File.read!(path) == formatted
  end

  test "stdin uses the same converged formatter", %{path: path} do
    {formatted, status} = format(["-"], path)
    assert status == 0, formatted
    assert formatted =~ ~s(#{String.duplicate("x", 90)}",\n)
    assert formatted =~ "    ],\n  },\n}"
    File.write!(path, formatted)
    assert_success(format(["--check-formatted", "-"], path))
  end

  test "checking an unformatted explicit file fails without rewriting it", %{
    path: path,
    source: source,
  } do
    {output, status} = format(["--check-formatted", path])
    assert status != 0, output
    assert output =~ "not formatted"
    assert File.read!(path) == source
  end

  defp format(args, input_path \\ nil) do
    options = [cd: @root, env: [{"MIX_ENV", "dev"}], stderr_to_stdout: true]

    if input_path do
      System.cmd(
        "sh",
        ["-c", ~s(exec mix format "$@" < "$FORMATTER_TEST_INPUT"), "formatter-test" | args],
        options
        |> Keyword.put(:env, [{"MIX_ENV", "dev"}, {"FORMATTER_TEST_INPUT", input_path}])
        |> Keyword.put(:stderr_to_stdout, false)
      )
    else
      System.cmd("mix", ["format" | args], options)
    end
  end

  defp assert_success({output, status}) do
    assert status == 0, output
  end
end
