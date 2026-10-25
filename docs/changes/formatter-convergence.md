# Formatter convergence

Product spec impact: none. Overview, runtime behavior and architecture are unchanged.

FreedomFormatter 2.1.3 decides whether to add trailing commas from the input's
newline metadata before wrapping long expressions. A newly wrapped list, map or
struct therefore needs a second pass to gain its commas. This is the open
[upstream issue #9](https://github.com/marcandre/freedom_formatter/issues/9);
2.1.3 remains the latest published Hex version at the time of this change.

Guardian's two-pass Mix alias did not solve explicit-file formatting: Mix forwards
the command's arguments to the first original-task entry and consumes them there.
The second entry received no arguments and formatted the default repository inputs.
Thus `mix format /tmp/repro.exs` formatted that file only once, and the following
`mix format --check-formatted /tmp/repro.exs` rejected its missing commas.

The alias is removed. The small `Guardian.Formatter` plugin in `.formatter.exs`
calls FreedomFormatter twice on each input string. Mix continues to handle paths,
stdin and check-only behavior. FreedomFormatter stays a dev-only dependency, and
the existing style, including trailing commas, stays unchanged. Applying two
passes to all existing formatter inputs produced zero byte changes.

The normal suite exercises the real Mix CLI with a temporary long single-line
nested map/struct/list. It checks that one invocation adds the expected commas,
passes check-formatted and is stable on repetition, that stdin does the same,
and that a failing check does not rewrite its input. No application starts in
these subprocesses. Remove the adapter when the upstream formatter converges on
its own.

Validation: all three focused CLI regressions pass on Elixir 1.19.3 /
OTP 28.5.0.8. A separate boundary probe of 2,640 nested list/map/struct samples
(depths 1–8 and string widths 1–110) converged in two passes. Independent Claude
and Codex plan and code reviews approved the change; small test-diagnostic
suggestions were incorporated. The sole full pre-commit run passed formatting,
compilation with warnings as errors and 1,197 tests with zero failures (three
large tests excluded).
