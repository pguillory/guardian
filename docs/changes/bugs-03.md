# Small review findings: bugs-03

Product spec impact: section 3.2 of `docs/product/spec.md` replaces the JSON API's
printed-query-fragment gap with kind and generated-ID failure logging inside its
error boundary. Overview impact: none. No disk format or supervision changes.

Four findings from the earlier review still applied after the Guardian namespace
and path moves:

1. `bin/install-git-hooks` treated `.git` as a directory. It now resolves Git's hook
   path, supports repository-local hooksPath settings and quotes paths with spaces.
   The link uses the main checkout's hook. With the default or an absolute hooks
   path, removing the installing worktree cannot break it; relative hooks paths
   live inside each worktree. Shared hooksPath settings and unsupported source layouts are refused
   before writing. Temporary-repository tests isolate Git configuration and cover
   normal/linked checkouts, removal of the installing worktree, relative/absolute
   hooksPath and refusal of global hooks. Fixture commands clear every inherited
   Git environment variable, including the outer commit hook's index/object paths.
2. `Guardian.Rules.Server` passed unrecognized stack frames through unchanged.
   These now become a valid fixed redacted frame; ordinary MFA frames retain only
   arity and typed file/line metadata. The existing crash regression now injects a
   source-bearing fun frame (a valid BEAM stack shape) as well as a normal
   function-clause failure, checking that source stays out of the crash log.
3. The segment test for preserving the first row's timer used a 100 ms real expiry
   across two appends. It now keeps a long timer, checks its identity, delivers the
   expiry explicitly and checks rollover and both stored rows. Natural timer expiry
   still has separate coverage.
4. The JSON API printed full exceptions. It now logs a safe failure kind and a
   random 64-bit ID only, with the same bare 500 response. Replacing the print alone
   was insufficient: Plug.ErrorHandler reraised into Bandit's full exception log.
   The JSON router now contains failures, recovering the connection from wrapped
   route errors and preserving already-sent responses. Unwrapped failures close
   HTTP/1 connections rather than drain body bytes the parser already consumed;
   a direct response-header assertion pins this behavior and a split-body socket
   test checks the Expect/continue path. A failure after sending
   raises only a safe replacement exception with an empty stack, letting Bandit
   close without logging the original data. Bandit transport/protocol failures
   pass through to preserve its status, cleanup and quiet disconnect handling.
   Specialized body and query
   string error responses keep their fixed messages and do not log. Recorder tests
   now assert returned responses rather than reraised exceptions while retaining
   stored error/message checks. Direct boundary and real-listener regressions cover
   redaction; security.md distinguishes logging from privileged raw Plug telemetry.

Deferred: `Guardian.Storage.Flattening.decode_path/1` still raises on an
unterminated quoted key. This optional hardening needs a deliberate malformed-input
contract; normal ingestion generates valid encoded paths. Stored malformed names
can reach the internal Segment row reconstruction path. No decoding behavior was
changed in this batch.

Validation covers focused hook, rules, segment, JSON boundary and query-recorder
regressions and independent Claude/Codex reviews. The full pre-commit hook runs
formatting, compilation and tests with warnings as errors at commit. The hook fixtures
were also checked with a fake inherited outer index path; the JSON tests use direct Plug
calls and the real local HTTP listener.
