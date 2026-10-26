# Guardian.Query.DistributedStream

`Guardian.Query.DistributedStream` (`lib/guardian/query/distributed_stream.ex`) is the multi-node
pipeline every query runs on. It was vendored from `distributed_stream` 0.1.4 (by
Preston Guillory, MIT license; see `LICENSE` here) and its failure model rewritten in
Guardian. It is internal to Query: only
`Guardian.Query.Executor` builds pipelines. Its moduledoc is the contract: the API, the failure
model, and the exit reasons `Guardian.Query.Failure` translates.

This is the hardest protocol in the system. Change it only with the rules below in
mind, and keep the comments in the file in step with them.

## Processes

1. The consumer (the process enumerating `fan_in/1`'s stream; for a query, the query
   process) links one router per stage and the final router. The first router
   starts the initial worker, which reads the input. The final router routes to the
   consumer: it answers each last-stage `{:spawn}` with the consumer's pid and, when
   the last stage is done, sends the consumer `{:done, id, senders}` like any router
   sends its workers, then exits. Routers get `{:done, id}`; receivers (workers and the consumer) get
   `{:done, id, senders}`, gather the same way, and differ only in how they fail
   (see Stopping item 2).
2. Routers trap exits and start workers (the final router starts none) with
   `Node.spawn_link/2`, one per `{node, shard}`, on the first `{:spawn}` for it. A
   worker exit reaches its router, and a router exit reaches the consumer. Abnormal
   exits propagate as is; nothing converts a crash into a normal end.
3. A worker sends `{:finished}` to its router after all its markers and only if its
   input was drained. A router treats a worker's normal exit without `{:finished}`,
   or before the upstream stage is done, as a failure. The first router links the
   initial worker (`spawn_link` from the router itself, not a monitor set up after
   the fact, which would see `:noproc` for an input that already ended) and treats
   its normal exit before its `{:done}` as `:input_exited`.
4. Every worker, including the initial worker, calls `Guardian.Query.Limits.limit_heap/0`
   first, on its own node, so each machine applies its own heap limit. Routers and the
   final router do not. A worker killed by it exits `:killed`, which
   `Guardian.Query.Failure.from_exit/1` turns into the heap-limit message.

## Messages and edges

1. Every protocol message carries the pipeline's `id` (a ref). A process can take part
   in several pipelines (nested pipelines, or one after another), so every receive
   matches the id.
2. A sender opens an edge by sending `{:spawn}` to the next stage's router and blocking
   on `{:spawned}`, monitoring the router meanwhile. The router records the sender for
   that worker before replying, so when the upstream stage sends `{:done}`, each
   worker's sender set is complete.
3. One chunk is in flight per edge: a sender waits for `{:ready_for_input}` before the
   next chunk. The first chunk is acknowledged before the sender goes on, so the
   receiver is already monitoring the sender if it then dies (and learns the real
   reason, not `:noproc`).
4. A chunk closes once its values reach `@chunk_size_bytes` of
   `:erlang.external_size/1`, so a single value can exceed it.
5. A sender ends each edge with `{:end_of_input, id, sender, chunks}`. The receiver
   fails with `{:lost_input, n}` if the count differs from what arrived, and finishes
   only when every sender its router named in `{:done, id, senders}` has sent its
   marker; any other sender fails it with `:unexpected_sender`.
6. Both ends of an edge monitor each other. A peer that goes down while still needed
   fails the pipeline: a crash reason is passed on unchanged (the links carry the same
   root cause, so either path gives the same reason), and `:normal`, `:noproc` and
   `:noconnection` become `{:distributed_stream, {edge, reason}}` (`edge_down_reason/2`).
   Edge checks exist because a connection between two worker nodes can drop and
   reconnect without breaking any link: all links run through the consumer's node.

## Stopping

1. Nothing waits with a timeout. Only `partitions/1`'s lookup has one (5 s).
2. The consumer fails by first stopping the rest of the pipeline with
   `{:shutdown, :pipeline_failed}`, then exiting with the real reason, so a consumer
   that catches the exit leaves nothing running and large reasons (which can carry
   row values) go only to the consumer.
3. Enumeration stopped early stops the pipeline with `{:shutdown, :halted}`.
4. `stop_pipeline/2`'s order matters: trap exits, signal every linked process, unlink
   them all, restore the trap flag, flush their EXIT messages, demonitor the senders,
   then flush this pipeline's messages. Trapping while signalling keeps one process's
   failure from killing a non-trapping consumer mid-stop; unlinking only after all are
   signalled means a consumer killed meanwhile still takes the rest down through its
   links. The cost: an outside exit signal that a non-trapping consumer handles while
   the flag is on becomes an EXIT message. It was not reproduced, so it is documented, not
   fixed.
5. Stages must read all their input. A transform that stops early fails the
   pipeline (`:worker_finished_early`) instead of finishing with partial output; the
   drained flag (`record_drained/1`) is the only evidence.

## Changing it

1. A new exit reason goes in the `failure_reason` type, the moduledoc list, and
   `Guardian.Query.Failure.from_exit/1` together.
2. Closures and the `node_schedulers/0` multicall run on other nodes by module name,
   so every node must run the same build.
3. Stage functions that tests run on peers live in
   `libtest/guardian/test/distributed_stream_stages.ex`: test modules aren't loaded there.
4. Run `test/guardian/query/distributed_stream_test.exs`, `test/guardian/query/distributed_stream/`,
   `test/guardian/query/pipeline_failures_test.exs`, `test/guardian/query/failure_test.exs` and
   `test/guardian/cluster/query_failures_test.exs`, then the full suite.
