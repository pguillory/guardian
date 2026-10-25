# One module per file

Status: complete.

Each file under `lib/` and `libtest/` defines one module or protocol, at the path
matching its name. Four files defined more than one and were split without changing
any module's name or body:

- `lib/guardian/rules/step.ex` keeps `Guardian.Rules.Step`; the per-kind structs
  moved to `step/set.ex`, `step/unset.ex`, `step/track.ex` and `step/lookup.ex`.
- `Guardian.Rules.Runtime.Failure` moved out of `Guardian.Rules.Runtime` to
  `rules/runtime/failure.ex`.
- `Guardian.Query.Evaluation.SegmentSnapshot` moved out of `Guardian.Query.Evaluation`
  to `query/evaluation/segment_snapshot.ex`.
- `Guardian.CounterPipelineProbe` moved out of `libtest/guardian/counter_client_helper.ex`
  to `libtest/guardian/counter_pipeline_probe.ex`.

The two parents that referred to a formerly nested module by its short name now
alias it explicitly.

A `defimpl` stays with the protocol or struct it implements and does not count:
the AST nodes' `Guardian.Query.Eval` implementations (placed beside each struct by
design), the protocol's `Any` fallback beside the protocol, and the S3 store's
`Inspect` implementation, which keeps its credentials out of inspected output. The
vendored DistributedStream `Enumerable` implementation keeps its own file.
Test files keep their small inline support modules.

CONTRIBUTING.md states the rule, beside a related one: generic mechanisms belong in
generic layers, not inside a feature module (documentation only). The definition-style
scan test now also checks that every `lib/` and `libtest/` source file defines at
most one module, counting nested
`defmodule` and `defprotocol` calls but not quoted code, and scanning `defimpl`
bodies. This supersedes "multi-module files remain whole" in
`guardian-module-paths.md`.

Product spec impact: none. Architecture impact: none. No runtime behavior changes.
