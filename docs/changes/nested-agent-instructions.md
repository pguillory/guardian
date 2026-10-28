# Nested agent instructions

Codex discovers AGENTS.md along the path to its starting directory. Guardian's
subsystem rules live in nested AGENTS.md files, so a builder starting at the
repository root must explicitly read the instructions for the files it edits.

The original change exposed subsystem rules through adjacent relative instruction
symlinks, matching the root pattern. That arrangement and its link regression
test are superseded by [canonical instruction files](canonical-agent-instructions.md).
AGENTS.md is now the real canonical file throughout the repository.

The root instructions and contributor guidance require reading every existing
AGENTS.md from `lib/` down to a target file's directory before editing it,
including a future `lib/AGENTS.md` if one is added. Automatic startup discovery
does not replace this explicit reading rule.

Product spec impact: none. No runtime behavior or architecture changes.

## Original validation

All 17 original nested symlinks used the relative target `CLAUDE.md`, resolved
to adjacent files, and were tracked with Git mode 120000. Independent Claude and
Codex plan and code reviews approved both changes. The full pre-commit checkpoint
passed formatting, compilation with warnings as errors, and 1,178 tests with zero
failures (three large tests excluded), together with the preceding style change.

## Original regression coverage

Product spec impact: none. Overview impact: none.

`Guardian.AgentInstructionsTest` originally checked each tracked canonical file
for an adjacent, resolving relative instruction symlink tracked with Git mode
120000. Discovery used Git's index, including newly staged files, excluding
dependency and build directories. A nested-file sentinel prevented an empty or
root-only scan from passing. This repository check requires Git and a Git checkout.

The original regression passed for the root and 17 nested instruction files in
the combined follow-ups' 317 focused tests (zero failures; three large tests
excluded). A final index-mode check passed a focused rerun; removing a link from
an isolated temporary index made the regression fail as expected, without changing
the working tree or real index.

Final combined checkpoint: independent Claude and Codex plan and code reviews
approved; the full pre-commit passed formatting, compilation with warnings as
errors and 1,194 tests with zero failures (three large tests excluded).
