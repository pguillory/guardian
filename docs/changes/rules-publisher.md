# Extract the rules publisher

Status: implemented and validated.

Product spec impact: none. No statements change in overview.md or spec.md.
Hashes, counter keys, execution results, diagnostics and write admission stay
unchanged.

Guardian.Rules.Publisher is an internal synchronous helper, called inside
Server's scrubbed callbacks. It owns activation selection, exact prior-plan
recovery through published modules' plan/0, diagnostic combination and safe
logging, compilation, atomic publication, and the free/retired module pool.
Its state contains only module names and retirement statuses. There is no new
process, plan cache or metadata registry.

Server keeps startup/store reads and retries, reload/poll, locked writes,
stored-set admission, file/ETag caching, stale tracking, broadcasts and callback
redaction. It holds Publisher's pool value and forwards reclamation messages;
Publisher's timers therefore still target Server.

Compilation or pool failure publishes nothing, discards only unpublished code
and leaves the caller's pool value unchanged. Published modules remain callable
until ordinary retirement: the grace period, delete once, then soft-purge with
retries before a name returns to the free list. Startup and Server-only restart
reserve published names and retire any other loaded current or old code.

Coverage adds actual compiler refusal after an earlier successful compilation,
discard/reuse and unchanged publication, reservation of published names and both
current and old unpublished code after restart, duplicate reclamation, and soft
purge deferral while a process still executes old code. Existing Server coverage
continues to check pool exhaustion, delayed reclamation, restart/store outages,
counter dependency retention, diagnostics, redaction and repair admission.

Independent Claude and Codex plan and code reviews approved the synchronous
boundary; each code reviewer completed all five concern helpers. Nonblocking
review fixes clarified ownership documentation and strengthened retirement and
unchanged-hash reuse assertions. No separate follow-up refactor was identified.

Validation passed with warnings as errors: 72 focused Publisher, Server, counter
reload, Compiler and counter-plan tests, then 33 affected tests after review
fixes. The sole full pre-commit passed formatting, test compilation with warnings
as errors and the default suite: 1,224 tests, zero failures, three excluded large
tests. Early scratch formatting/compilation attempts caught a temporary extraction
error, corrected before these successful runs.

No deployment or production verification is included.
