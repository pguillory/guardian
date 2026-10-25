# Nested agent instructions

Codex discovers AGENTS.md along the path to its starting directory. Guardian's
subsystem rules live in nested CLAUDE.md files, so a builder starting at the
repository root must explicitly read the instructions for the files it edits.

Every nested CLAUDE.md now has an adjacent relative `AGENTS.md -> CLAUDE.md`
symlink, matching the existing root pattern. CLAUDE.md stays canonical. The root
instructions and contributor guidance require reading every existing CLAUDE.md
from `lib/` down to a target file's directory before editing it, including a future
`lib/CLAUDE.md` if one is added. Symlinks support agents starting inside a
subsystem; they do not replace the explicit reading rule.

Product spec impact: none. No runtime behavior or architecture changes.

Validation: all 17 nested symlinks have the relative target `CLAUDE.md`, resolve
to their adjacent canonical files, and are tracked with Git mode 120000. The
existing root symlink remains unchanged. Independent Claude and Codex plan and
code reviews approved both changes. The full pre-commit checkpoint passed
formatting, compilation with warnings as errors, and 1,178 tests with zero
failures (three large tests excluded), together with the preceding style change.

## Regression coverage

Product spec impact: none. Overview impact: none.

`Guardian.AgentInstructionsTest` checks every tracked `CLAUDE.md`, including the root
and all nested files, for an adjacent `AGENTS.md` symlink whose exact relative target
is `CLAUDE.md` and exists, and which is tracked with Git mode 120000. Discovery uses
Git's index, including newly staged files, so dependency and build directories are
excluded. New untracked instruction files
enter coverage when staged. A nested-file sentinel prevents an empty or root-only
scan from passing. This repository check requires Git and a Git checkout.

Validation: the regression passed with the root and all 17 nested instruction files
in the combined follow-ups' 317 focused tests (zero failures; three large tests
excluded). The final index-mode check passed a focused rerun; removing a link from
an isolated temporary index made the regression fail as expected, without changing
the working tree or real index.

Final combined checkpoint: independent Claude and Codex plan and code reviews
approved; the full pre-commit passed formatting, compilation with warnings as
errors and 1,194 tests with zero failures (three large tests excluded).
