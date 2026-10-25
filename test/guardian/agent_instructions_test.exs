defmodule Guardian.AgentInstructionsTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  test "tracked CLAUDE.md files have adjacent relative AGENTS.md symlinks" do
    # The index includes new staged instructions, without walking dependencies or
    # other worktrees. Untracked instruction files enter coverage when staged.
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

    paths =
      files
      |> Map.keys()
      |> Enum.filter(&(Path.basename(&1) == "CLAUDE.md"))

    assert "CLAUDE.md" in paths
    assert "lib/guardian/CLAUDE.md" in paths, "Scan must include nested instructions"

    for path <- paths do
      canonical = Path.join(@root, path)
      agent = Path.join(Path.dirname(canonical), "AGENTS.md")

      assert files[Path.relative_to(agent, @root)] == "120000",
             "#{path}'s AGENTS.md must be tracked as a symlink"

      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(agent),
             "#{path} needs an adjacent AGENTS.md symlink"

      assert {:ok, "CLAUDE.md"} = File.read_link(agent),
             "#{path}'s AGENTS.md must point to relative CLAUDE.md"

      assert File.regular?(canonical), "#{path}'s symlink target must exist"
    end
  end
end
