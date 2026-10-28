defmodule Guardian.AgentInstructionsTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  # Keep established coverage explicit: deleting a subsystem's instructions must
  # not make that subsystem disappear from the scan.
  @instruction_directories ~w(
    .
    lib/guardian
    lib/guardian/aggregation
    lib/guardian/ast
    lib/guardian/ast/node
    lib/guardian/ast/node/operators
    lib/guardian/ast/node/statements
    lib/guardian/counters
    lib/guardian/engine
    lib/guardian/object_store
    lib/guardian/query
    lib/guardian/query/distributed_stream
    lib/guardian/query/function
    lib/guardian/query/virtual_table
    lib/guardian/rules
    lib/guardian/storage
    lib/guardian/storage/column
    lib/guardian/web
    lib/guardian/web/mcp
  )

  test "AGENTS.md is the sole real instruction file in every subsystem" do
    # The index includes new staged instructions, without walking dependencies or
    # other worktrees. Untracked files are intentionally out of scope until staged.
    {output, status} = System.cmd("git", ["ls-files", "--stage", "-z"], cd: @root)
    assert status == 0, "Could not list repository instruction files"

    files =
      output
      |> String.split("\0", trim: true)
      |> Map.new(fn entry ->
        [metadata, path] = String.split(entry, "\t", parts: 2)
        [mode, _object, _stage] = String.split(metadata, " ")
        {path, mode}
      end)

    refute Enum.any?(files, fn {path, _mode} -> Path.basename(path) == "CLAUDE.md" end),
           "Remove CLAUDE.md files; AGENTS.md is canonical throughout the repository"

    for directory <- @instruction_directories do
      path = if directory == ".", do: "AGENTS.md", else: Path.join(directory, "AGENTS.md")
      assert Map.has_key?(files, path), "#{directory} needs a tracked AGENTS.md"
    end

    for {path, mode} <- files, Path.basename(path) == "AGENTS.md" do
      assert mode == "100644", "#{path} must be tracked as a regular instruction file"
      absolute = Path.join(@root, path)

      assert {:ok, %File.Stat{type: :regular}} = File.lstat(absolute),
             "#{path} must be a real file, never a symlink"

      assert String.starts_with?(File.read!(absolute), "# "),
             "#{path} needs instruction content beginning with a heading"
    end
  end
end
