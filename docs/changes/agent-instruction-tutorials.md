# Move instruction tutorials into documentation

Product spec impact: none. Overview impact: none. Runtime behavior, architecture,
native APIs and the segment format are unchanged.

## Split criterion

Keep requirements an editor must obey in the automatically loaded CLAUDE.md;
move descriptions, API inventories, walkthroughs and examples into docs/. Preserve
the adjacent relative AGENTS.md symlinks. The instructions remain authoritative;
the guides link back to them for safety and compatibility rules.

The two tutorial outliers were the query function instructions (450 lines) and
storage column instructions (322 lines). Other nested instructions are 10–164
lines and chiefly describe subsystem contracts and editing invariants, so they
remain in place. Length alone is not the criterion: ownership, concurrency and
failure rules still belong beside their code.

## Section mapping

| Original material | Destination and reason |
| --- | --- |
| Function purpose, dispatch walkthrough, seven patterns, utilities, adding a function, categories, worked test and related files | `docs/guides/query-functions.md`: contributor tutorial and reference. |
| Function registration, file/module naming, eval/eval2 and alias contracts, variable-arity joins, native dispatch | Function CLAUDE.md: required implementation contracts, including rules previously embedded in patterns/gotchas. |
| Function totality, type fallbacks, URL/regex safety, performance constraints and test requirements | Function CLAUDE.md: required safety and evaluation rules; examples remain in the guide. The Totality heading is preserved. |
| Column overview, API inventory, metadata layout and macro examples, usage, performance, debugging and related files | `docs/architecture/storage-columns.md`: mechanics and reference material. |
| Column stub/delegation parity, type/errors, numerical bounds, checked allocation, validation, list layers and mutable ownership | Column CLAUDE.md: native safety and API requirements. |
| Column metadata compatibility/commutativity and test matrix | Column CLAUDE.md: invariants, migration requirements and required coverage. |
| Column future considerations | Column reference: explicitly unscheduled optimization background, with a pointer to TODO.md; no new implementation work. |

The existing nonraising URL helper rule and native stub parity rule remain in the
short instructions. Removed column APIs are not restored. README and the
architecture index make the new pages discoverable; the system architecture's
descriptive column reference now points to the column page, while its native
validation reference still points to the editing rules.

## Validation

The function instructions are now 71 lines and the column instructions 62 lines.
All 59 relative Markdown links/anchors in the nine changed/new pages resolve,
and the canonical instruction symlinks still resolve to adjacent CLAUDE.md files.
The section mapping above was checked against the original files, including the
rules embedded in examples and gotchas. No application source or tests are changed.

Independent Claude and Codex plan reviews approved the split. The Codex code
review approved after five concern helpers; its non-blocking clarification that
the scalar eval/N requirement applies only without eval2/2 was incorporated.
Claude's code review was unavailable after a session-limit failure and one retry,
so the code-review gate used the permitted single-provider reduction.

The single full pre-commit checkpoint passed formatting, compilation with
warnings as errors and 1,306 tests with zero failures (three large tests excluded;
seed 856853). Dependencies emitted their existing fresh-build warnings. The
validation record was then updated and staged whitespace checked again; the
commit does not repeat the full suite.
