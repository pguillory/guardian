# Canonical agent instructions

AGENTS.md is the sole canonical instruction filename in Guardian. The root and
all 18 existing subsystem instruction files are real files, replacing CLAUDE.md
and adjacent AGENTS.md symlinks. Editing rules are preserved; references
throughout documentation, source comments, contributor guidance and change records
now point to AGENTS.md. The earlier symlink arrangement described in
[nested instructions](nested-agent-instructions.md) is superseded.

Instruction-file paths in older change records now use the current AGENTS.md
names so contributors can still find the rules. This filename migration is an
exception to preserving historical names; it does not change what those earlier
commits contained. Earlier work used CLAUDE.md; adjacent AGENTS.md symlinks were
introduced by the nested-instructions change. Historical helper module names and
original validation results remain unchanged.

Before editing under `lib/`, read every existing AGENTS.md from `lib/` down to the
edited file's directory. Codex startup discovery follows the path to its starting
directory; it does not automatically read arbitrary descendants.

Product spec impact: only the introductory reference to per-subsystem instruction
files in `docs/product/spec.md` changes to AGENTS.md. Overview impact: none.
Runtime behavior and architecture are unchanged.

## Claude Code compatibility

Verified against installed Claude Code 2.1.310 and Anthropic's documentation. The
[2.1.277 release notes](https://github.com/anthropics/claude-code/releases/tag/v2.1.277)
introduced AGENTS.md fallback when a project has no CLAUDE.md.
The official [built-in instruction documentation](https://github.com/anthropics/claude-code/blob/main/mods/agents-md/README.md)
confirms the default `claude-md-or-agents-md` mode loads root/ancestor AGENTS.md
files and attaches nested instructions when reading files below them. Personal
global instructions do not suppress project fallback. This depends on a supported
Claude Code version with its built-in instruction plugin enabled and the default
or both-filenames mode; clients configured to load only the former filename need
their instruction setting changed.

## Regression coverage

The normal suite rejects the former filename anywhere in Git's index, requires
AGENTS.md in all 19 established instruction directories, and checks every indexed
AGENTS.md is a regular file both in Git and on disk, with an instruction heading.
New staged instruction files enter coverage automatically. Untracked and ignored
files are outside this repository-layout check; dependencies, build outputs and
other worktrees are not traversed.

## Validation

All 19 instruction bodies were compared against their former canonical Git
blobs, allowing only the intended filename substitutions and root read-rule/date
update. The focused instruction test passed. Isolated Git-index probes rejected
a missing nested file, the former filename in a new location, and a symlink at a
new instruction path. All 23 migrated instruction/change Markdown links resolve.

Independent Claude and Codex plan reviews approved. Both code reviewers completed
all five concern reviews. Codex approved without findings; Claude's only requested
change was clarification of historical filename wording, which was incorporated.
The remaining suggestions were optional hardening or presentation changes; no
follow-up refactor was identified.

The single full pre-commit checkpoint passed formatting, compilation with warnings
as errors, and 1,337 tests with zero failures (three large tests excluded; seed
197597). The focused instruction test passed again after the review edits. Final
validation-record edits were staged and checked for whitespace without repeating
the full suite.
