defmodule Guardian.GitHooksTest do
  use ExUnit.Case, async: true

  @installer Path.expand("../../bin/install-git-hooks", __DIR__)

  setup %{tmp_dir: directory} do
    repository = Path.join(directory, "main checkout")
    File.mkdir_p!(Path.join(repository, "bin"))
    File.cp!(@installer, Path.join(repository, "bin/install-git-hooks"))
    hook = Path.join(repository, "bin/pre-commit")
    File.write!(hook, "#!/bin/sh\nprintf 'main hook\\n'\n")
    File.chmod!(hook, 0o755)
    global = Path.join(directory, "global config")
    File.write!(global, "")

    # Git exports its index/object paths when this suite runs inside a commit hook.
    # No fixture command may inherit those paths from the enclosing repository.
    env =
      System.get_env()
      |> Map.filter(fn {key, _value} -> String.starts_with?(key, "GIT_") end)
      |> Map.new(fn {key, _value} -> {key, nil} end)
      |> Map.merge(%{"GIT_CONFIG_GLOBAL" => global, "GIT_CONFIG_NOSYSTEM" => "1"})
      |> Map.to_list()

    context = %{repository: repository, env: env, global: global, tmp_dir: directory}
    git(context, ["init", "--quiet"])

    git(context, [
      "-c",
      "user.name=Hook Test",
      "-c",
      "user.email=hook@example.invalid",
      "-c",
      "commit.gpgsign=false",
      "commit",
      "--quiet",
      "--allow-empty",
      "-m",
      "fixture",
    ])

    context
  end

  @moduletag :tmp_dir

  test "installs in the common hooks directory from a normal checkout", context do
    install(context)
    assert_hook(context, Path.join(context.repository, ".git/hooks/pre-commit"))
  end

  test "a hook installed from a linked worktree survives its removal", context do
    linked = Path.join(context.tmp_dir, "linked checkout")
    git(context, ["worktree", "add", "--quiet", "--detach", linked])
    File.mkdir_p!(Path.join(linked, "bin"))
    File.cp!(@installer, Path.join(linked, "bin/install-git-hooks"))
    assert File.regular?(Path.join(linked, ".git"))
    install(%{context | repository: linked})
    # The untracked fixture installer must be removed before Git removes the worktree.
    File.rm!(Path.join(linked, "bin/install-git-hooks"))
    File.rmdir!(Path.join(linked, "bin"))
    git(context, ["worktree", "remove", linked])
    assert_hook(context, Path.join(context.repository, ".git/hooks/pre-commit"))
  end

  test "honors repository-local relative and absolute hooksPath", context do
    for directory <- ["custom hooks", Path.join(context.tmp_dir, "absolute hooks")] do
      git(context, ["config", "core.hooksPath", directory])
      install(context)
      assert_hook(context, Path.expand(Path.join(directory, "pre-commit"), context.repository))
    end
  end

  test "refuses a global hooksPath without writing to it", context do
    shared = Path.join(context.tmp_dir, "shared hooks")
    git(context, ["config", "--file", context.global, "core.hooksPath", shared])

    assert {output, 1} =
             System.cmd("bash", ["bin/install-git-hooks"],
               cd: context.repository,
               env: context.env,
               stderr_to_stdout: true
             )

    assert output =~ "Refusing"
    refute File.exists?(shared)
  end

  defp git(context, args) do
    assert {output, 0} =
             System.cmd("git", args,
               cd: context.repository,
               env: context.env,
               stderr_to_stdout: true
             )

    output
  end

  defp install(context) do
    assert {"", 0} =
             System.cmd("bash", ["bin/install-git-hooks"],
               cd: context.repository,
               env: context.env,
               stderr_to_stdout: true
             )
  end

  defp assert_hook(context, path) do
    assert File.read_link!(path) == Path.join(context.repository, "bin/pre-commit")
    assert {"main hook\n", 0} = System.cmd(path, [], cd: context.repository, env: context.env)
  end
end
