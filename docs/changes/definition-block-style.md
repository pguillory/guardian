# Block syntax for definitions

Function and macro definitions consistently use `do...end` blocks. Keyword-form
bodies made short clauses harder to read and encouraged awkward indentation.
Existing definitions in `lib/`, `libtest/`, and `test/` were converted without
changing their bodies, guards, or clause order. Keyword control-flow expressions
remain allowed.

The convention lives in CONTRIBUTING.md. A parser-based source scan runs in the
normal test suite, including quoted definitions and multiline bodies, while
ignoring strings, comments, declarations without bodies, and `defdelegate`.
Instructional examples use the same style.

Product spec impact: none. No runtime behavior or architecture changes.

Validation: all 127 converted source files (690 definitions) retain identical
metadata-stripped Elixir syntax trees and comment text. Focused scan tests passed
(four tests). Independent Claude and Codex code reviews approved both changes;
non-blocking scan robustness and error-location suggestions were incorporated.
The full pre-commit checkpoint passed formatting, compilation with warnings as
errors, and 1,178 tests with zero failures (three large tests excluded). It ran
once on this change together with the instruction-only change that follows it;
the first commit's code is identical to that tested tree.
