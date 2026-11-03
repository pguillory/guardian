# The rule write lock is tested across real nodes

Status: implemented.

Product spec impact: none. No statements change in `docs/product/overview.md` or
`docs/product/spec.md`. Only tests change.

## Problem

`Guardian.Web.MCP.RulesToolsBusyTest` checked that a rule write finding the write lock
held fails as busy and saves nothing, and that the MCP `write_rule` tool reports a busy
write once its retries run out. It took the lock itself, from outside the rule server,
which no real caller does, and holding the one lock made it the last `async: false`
module in the default suite. Preston's call: the lock is a cluster concern, so the test
belongs in the cluster suite, where another node's rule server really holds it.

## Change

1. `Guardian.Rules.ClusterTest` gains both cases. A peer's rule server writes a rule and
   holds the lock while it waits, before saving, for every other node to clear old code
   for the new rules; a second peer's rule server is suspended (`:sys.suspend/1`), so the
   peer waits on it for up to the 10 s check timeout. The test waits until the request
   reaches the suspended server, then writes from the test node: the write is `:busy`,
   and nothing is saved. The MCP tool's busy message is checked the same way. Resuming
   the second peer lets the held write finish, and the test node's write then succeeds.
2. `test/guardian/web/mcp/rules_tools_busy_test.exs` goes, with its lock fake.

The default suite (`mix test`) has no `async: false` module left; every remaining one is
tagged `:cluster` or `:lifecycle`.
