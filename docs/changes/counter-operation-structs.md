# Named counter operations

Status: implemented.

Product spec impact: none. No statements change in `docs/product/overview.md` or
`docs/product/spec.md`. This changes no behavior.

## Problem

`Guardian.Counters.Execution`'s input was `{:track, Definition.t(), tuple(), [term()]}`
or `{:lookup, Definition.t(), tuple()}`, which doesn't say what the tuple and the terms
mean.

## Change

`Guardian.Counters.TrackOperation` (`definition`, `group`, `values`) and
`Guardian.Counters.LookupOperation` (`definition`, `group`) replace them.
`Guardian.Rules.Runtime` builds them and `Execution` consumes them.

They stop at Execution, which expands each into store operations. The store operations
that go through `Client.batch/2` and across nodes (`{:get, key}`, `{:gets, key}`,
`{:incr, ...}`, `{:cas, ...}`) stay tuples, because they're the wire format between
nodes. Naming those is a separate question, and it would need boundary conversion or an
all-nodes restart.

## Rolling deploys

No wire change. Operations are built per event and never leave the node, and
`Transport.remote_operation/3`'s arguments and replies are unchanged. A run with the
caller and the owner on different builds, in both directions, gave the same results as
same-build runs.

## Tests

Execution's and the Rules counter tests build the structs, and the existing rule-path
tests exercise both of Runtime's construction sites. On the counter path, 32 alternating
runs of 20,000 events (four statements each, local store) had a median of 47.25 µs per
event before and 48.16 µs after, about 2%.
