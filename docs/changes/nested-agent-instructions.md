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
