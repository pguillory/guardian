# ingest-rules: SET and UNSET rules run on incoming events, stored as files

Status: phase 1 (SET and UNSET) done. TRACK and LOOKUP are designed here so they fit
later, but are not built. The open questions were settled on the recommendations
below. Each was first kept switchable through app env (`:rules_on_failure`,
`:rules_invalid_at_boot`); once confirmed, the switches and the alternatives they
selected were removed. Rollout to a deployment is separate.

## Problem

Guardian stores events exactly as they arrive. A producer that wants a derived field
(a severity, a normalized email, an `is_blocked` decision) has to compute it before
sending, and a field that must never be stored (a password, a debug payload) has to
be stripped by every producer. Guardian once had a rule engine that did this at
ingest time (removed in 2026-09 with PostgreSQL and Memcached); this brings back its
stateless half without any of those services. Rules are plain files, so they can be
reviewed, diffed and backed up like code.

## Behavior after the change

### Rule files

1. Rules are files named `<table>/<name>.gsql`. The folder names the table the rules
   apply to; `<name>` is a label (`[a-z0-9_][a-z0-9_-]*`, at most 64 bytes). The
   table must be a valid Guardian table name and not one of the built-in tables
   (`system_stats`, `web_requests`, `web_responses`, `query_parse_errors`,
   `queries`): rules run only on events sent through the ingest APIs.
2. A file holds one or more statements separated by `;`, with `--` comments, at most
   64 KiB. Limits on the whole set: 1,000 files, 256 tables with rules, 1,000
   statements per table.
3. Phase 1 statements:

   ```sql
   SET severity = 'high'
   SET severity = 'high' WHERE status >= 500
   UNSET password
   UNSET debug_payload WHERE env = 'prod'
   ```

   `SET field = expr [WHERE cond]` sets a field. `UNSET field [WHERE cond]` removes
   one. Expressions and conditions are the query language's scalar expressions (all
   scalar functions, operators, CASE). Aggregates are rejected anywhere in a
   statement, WHERE included.
4. Later, not built now, the same grammar takes:

   ```sql
   TRACK logins_last_hour = count() BY ip LAST '1h'
   TRACK spend_today = sum(amount) BY user_id WHERE status = 'ok' LAST '1d'
   LOOKUP prior_logins = logins_last_hour BY ip
   LOOKUP user_spend = spend_today FROM transactions BY buyer_id WHERE amount > 100
   ```

### Grammar

```text
rule_file   := [statement] (';' [statement])*
statement   := set | unset                        -- phase 1
             | track | lookup                     -- later
set         := SET field '=' expr [WHERE expr]
unset       := UNSET path [WHERE expr]
track       := TRACK name '=' aggregate_call [BY expr (',' expr)*] [WHERE expr] LAST string
lookup      := LOOKUP field '=' counter_name [FROM table] [BY expr (',' expr)*] [WHERE expr]
field       := identifier without dots
path        := identifier, dots allowed, no list boundaries ('..')
```

1. `SET`, `UNSET`, `TRACK`, `LOOKUP` and `LAST` are recognized only by position in
   the rule parser, not added as tokenizer keywords. Adding keywords would make
   them reserved table names and break queries that use `set` or `last` as column
   names. `WHERE`, `BY` and `FROM` are already keywords. The expression parser
   returns at a token it cannot continue with, so `LAST` ends a TRACK's WHERE or BY
   (tests pin `SET set = last`, `UNSET last`, and that LAST is never read as an
   alias).
2. The rule parser is a new entry point (`parse_rules`) beside the query parser,
   sharing its tokenizer and expression parser. A query cannot contain a rule
   statement and a rule file cannot contain a query.
3. One field per statement; there is no `SET a = 1, b = 2`.
4. Identifiers are lowercased by the tokenizer, as in queries, so `SET Severity`
   defines `severity`.

### Semantics

1. Rules run on each event sent through `/api/json/send_events` or MCP
   `send_events`: the event is flattened and its invalid values dropped as today,
   then the rules run on that row, then the values the rules produced are validated
   the same way (one that cannot be stored is dropped), then the row is stored.
   Guardian's own writes to built-in tables do not run rules.
2. Reads: a field the event lacks is null, with no warning. There is no declared
   schema and no check that a field exists. Rules see the flattened row, so an
   object field has no value of its own (`card` is null when the event has
   `card.number`); read the leaf (`card.number`). Names match ignoring case: an
   exact match wins, otherwise the first case-insensitive match in byte order. This
   differs from queries, which reject an ambiguous name, because a rule must give
   every event a result.
3. `SET x` replaces the whole incoming field: it first removes every column whose
   top-level field matches `x` ignoring case (`x`, `X`, `x.*`, `x..*`), then stores
   the new value as `x`. So `SET email = lower(email)` on `{"Email": "A@B"}` stores
   only `email`, and `SET user = 'redacted'` on `{"user": {"name": "Bob"}}` stores
   only `user`.
4. `UNSET p` removes every column matching the path `p` ignoring case, and every
   column beneath it (`UNSET password` removes `password`, `Password` and
   `password.hash`).
5. `WHERE` applies the statement only when it evaluates to true; false or null
   leaves the field as the event sent it.
6. Order within a table: every SET runs before every UNSET, so a SET can read a field
   that an UNSET removes (`SET has_card = card_number IS NOT NULL; UNSET
   card_number`). SETs run in dependency order (reads in the value and in WHERE
   both count): one that reads a field another SET writes runs after it.
   Independent statements run in file-name then statement order. A SET that reads
   its own field reads the incoming value (`SET email = lower(email)`), and runs
   once however many files contain it.
7. Rules run in a short-lived worker process with the query heap limit
   (`GUARDIAN_QUERY_MAX_HEAP_MB`), not in the request process (MCP calls share one
   Anubis server process). The worker takes a batch's events in order and sends
   each event's rule result back as it finishes; the request process stores it.
   Each event has a 1 s rule time limit. If the worker exceeds that or its heap
   limit, or dies, that event fails, and a new worker continues with the next one,
   so every event gets its own ordered outcome. Query functions keep their own
   bounds (regular-expression backtracking limits, `replace`'s size handling).
8. A statement that raises, or an event over its time or heap limit: see open
   question 1. The worker catches its own raises; its log line names the rule file
   and line (for a raise) or the table and limit (for a kill) and the failure's
   kind, never a value, at most once a minute per file and node. Heap kills are
   reported without the error_logger report, so no crash report carries an event's
   values.
9. A reload while a batch runs may apply new rules to its later events; each event
   sees one consistent rule set.
10. Rules have no external calls and no state. TRACK will need counter state; where
    it lives is explicitly deferred.
11. Direction for TRACK and LOOKUP (notes, not a design): a rule must never error
    or run slow because of the rule itself, so their semantics are constrained
    rather than checked at run time. A LOOKUP of a missing key gives null (or 0 for
    a count); BY is an exact key, not a pattern; counters live in memory in fixed
    time buckets with a cap on keys; and each update is O(1).

### Validation

Every write validates the whole rule set, all tables together. A write is rejected
if it adds an error the stored set did not already have (errors compared by file,
kind and message, ignoring line and column, so an edit that only moves lines does
not make an old error new). Deletes follow the same rule; in phase 1 a delete can
never add an error, and later deleting a TRACK a LOOKUP uses is rejected by it. So a set already broken (a hand
edit, or an upgrade that dropped a function used in two files) can be repaired one
file at a time, and an error in one table does not block writes to another. Every
result lists the errors that remain. Errors, each naming the file and line:

1. a file fails to parse, uses an unknown function, or uses an aggregate;
2. a file path is invalid (table name, file name, built-in table) or a limit is
   exceeded;
3. a field on one table is defined two different ways: any two statements on the
   same field (two SETs, a SET and an UNSET, or two UNSETs of one path) that differ
   once parsed and unparsed
   (`to_source`, so whitespace, comments and keyword case do not matter; literals
   and WHERE do). Identical duplicates are one definition. Conditional alternatives
   go in one statement with CASE or `if()`;
4. SET statements on one table form a cycle (`SET a = b; SET b = a`). A self-read is
   not a cycle.
5. Later: a LOOKUP must resolve to a TRACK of that name on its own table or its FROM
   table, and deleting a TRACK a LOOKUP uses is rejected. A LOOKUP defines a field
   in its table's field namespace. A TRACK names a counter; whether it also writes
   the counter's value onto the event, as the old engine's did, is decided with
   TRACK. The intent is that TRACK sees the row after SETs and before UNSETs.

A stored set can still turn out invalid (a hand edit of the store, a build that
removes a function, or the lock race below). Loading handles that per table (see
"Loading"), and operators can always also edit the files in the store directly.

### Ingest response

The ingest APIs already take `return_keys`; this was how the old rule engine
returned computed fields, and it carries over. Rules run before the response is
built, so a requested field reflects them:

```json
{"table": "logins", "events": [{"ip": "203.0.113.9", "signal": 0.97}],
 "return_keys": ["is_blocked"]}
```

```json
{"status": 200, "results": [{"success": true, "event": {"is_blocked": true}}]}
```

1. A requested key the stored event lacks now comes back as `null` instead of being
   left out, so a client can always read it. This changes today's responses (keys
   used to be omitted); the spec and API reference call it out.
2. The reported event is built from the row after rules: Engine's current shortcut
   (report the original event when nothing was dropped) applies only when the rules
   changed nothing. Omitted or null `return_keys` returns the stored event,
   including computed fields and without unset ones.
3. HTTP and MCP share this through `Web.Ingest`.

### MCP tools

1. `list_rules` (optional `table`): each file's table, name and size.
2. `read_rule` (`table`, `name`): the file's source.
3. `write_rule` (`table`, `name`, `source`): creates or replaces a file.
4. `delete_rule` (`table`, `name`).

Results distinguish: rejected (every validation message, nothing saved); saved and
every node reloaded; saved but some nodes not yet confirmed (named; they catch up by
polling); and failed or unknown storage outcomes ("may have been saved; list to
check"). Writes are logged (table, name, outcome; never the source). There are no
JSON API rule endpoints in phase 1.

### Storage of rule files

1. Two backends behind one interface (list with ETags, get bound to an ETag,
   conditional put, delete):
   - Local folder (default): `GUARDIAN_RULES_DIR`, defaulting to
     `$GUARDIAN_DATA_DIR/rules`. Writes go to a temporary file and are renamed. The
     ETag is a hash of the content.
   - S3-compatible bucket (R2): on when `GUARDIAN_RULES_S3_BUCKET` is set, with
     `GUARDIAN_RULES_S3_ENDPOINT` (`https://`, or `http://` only for `localhost`,
     127.0.0.0/8 or `[::1]`), `GUARDIAN_RULES_S3_ACCESS_KEY_ID`,
     `GUARDIAN_RULES_S3_SECRET_ACCESS_KEY`, optional `GUARDIAN_RULES_S3_REGION`
     (default `auto`) and `GUARDIAN_RULES_S3_PREFIX`. Setting both a folder and a
     bucket, or only some of the bucket settings, refuses startup.
2. No index or manifest object and no local cache. Each object is one rule file;
   listing the bucket (prefix-scoped) is the index. Objects not ending in `.gsql`
   are ignored (the write lock below is one); a `.gsql` object at an invalid path
   is a validation error for its table.
3. Reading the set: list, then GET each object with `If-Match` on its listed ETag;
   a mismatch (changed between list and get) restarts the read, at most 3 times.
4. S3 client: Req with its built-in SigV4 signing (`aws_sigv4`, `service: :s3`,
   region `auto` for R2) and `:xmerl` (added to the release) for ListObjectsV2 with
   pagination. Req is one new dependency; Finch and Mint are already in the lock
   through anubis_mcp. Connect and receive timeouts 5 s and 15 s, TLS verification
   on, listed sizes checked against the 64 KiB limit before any GET.
5. Credentials stay out of logs, error messages and process crash reports. The
   config holds them in a zero-arity function; store calls run inside a wrapper
   that catches everything and returns a safe kind (HTTP status, `timeout`,
   `connect_failed`), so a `Req.Request` never appears in a raised exception. A test
   forces failures and checks the captured log for the secret. As security.md
   already says of every secret, a VM crash dump still contains them.

### Loading

1. Startup loads the rule set before anything else (Rules is the first child,
   ahead of Storage's segment loading, so a bad store fails in seconds). An
   unreachable or rate-limited (HTTP 429) store is retried with backoff for up to
   60 s, then refuses startup. A 429 on a save or delete means nothing was saved.
   A misconfigured store (partial settings, bad credentials, missing bucket)
   refuses startup at once. Errors name the cause, never a credential.
2. A stored table whose rules fail validation at startup: see open question 2.
   A running node instead keeps that table's previous good rules after a bad
   reload, so a node restarting into a bad set and a running one can differ until
   the set is fixed.
3. Reload and poll never replace good rules with bad: all changed tables compile
   before one map is published; a failure keeps the previous set and logs.
4. If the Rules process restarts while Guardian runs, it keeps serving the
   published set (it lives in `:persistent_term`, not the process) and reloads in
   the background, so a store outage cannot take the rest of Guardian down.

### Writes, locking and reload

1. The cluster-wide lock is an object in the store, `_write.lock`, not an Erlang
   lock, so it also holds across a network partition (two sides with `:global`
   would each get one). Its body names the holder (node and a random token); the
   lease is 120 s from the object's `Last-Modified`, judged against the store's own
   `Date` response header, so the lease is measured on the store's clock and node
   clock skew does not matter. A writer creates it with `If-None-Match: *`. On 412 it
   reads the lock: a released or expired lock is taken over with `If-Match` on the
   ETag it read; a live one is retried for up to 10 s, then the write fails with
   "another rule write is in progress". The local folder uses the same scheme with
   an exclusive create and rename.
2. Under the lock the writer reads the whole set from the store (not memory),
   applies its change, and validates (above).
3. It saves the one file (PUT, or DELETE), only if at least 80 s of its lease
   remain, and with an overall 20 s deadline on that request (connect plus
   response). So a save that completes lands well inside the lease.
4. Release is ownership-safe: the writer overwrites the lock with a "released" body
   using `If-Match` on its own lock's ETag (S3 has no conditional delete), so it can
   never release a successor's lock. If the save's outcome is unknown (deadline,
   connection lost), the writer does not release: the lock stays held until its
   lease expires, so the next writer starts at least 60 s after the uncertain
   request was abandoned, and validates against whatever it finds.
5. It then tells every connected node (itself included) to reload and waits up to
   10 s. Nodes reload from the store, reading only objects whose ETag changed.
6. With the local-folder backend and other nodes connected, writes are rejected:
   each node has its own folder, so a cluster needs the bucket. A single machine
   works with either.
7. Every node lists the store every 60 s and reloads when any ETag differs, to
   catch a reload it missed. A failed poll keeps the current rules and logs at most
   once every 10 minutes. One LIST a minute is about 45,000 class A operations a
   month per node.
8. What this does not guarantee: S3 cannot make one object's write conditional on
   another, so without a commit object (ruled out: no manifest) no lock can fence a
   writer that stalls past its lease after the 80 s check, or a request the store
   applies more than 60 s after the writer abandoned it. Either can leave a set
   that validation would have rejected; loading handles it per table, and the
   next write reports it. See open question 3.

### Compilation

1. Each table's rules compile to a generated module with `apply(row)`, holding the
   table's ordered, deduplicated statements with their expressions as escaped AST
   literals (regular expressions as pattern strings, never compiled `:re`
   references) and running them through the query engine's scalar evaluator.
   Generated code comes only from fixed templates plus escaped data; no rule text
   becomes code. Generating native code per expression is a later optimization.
2. A compiled module is immutable: a module name is never loaded twice while
   anything can still call it. Names come from a fixed pool of 1,024
   (`Rules.Compiled.M0` to `M1023`), so atoms are bounded for the VM's lifetime
   however often rules change. The pool covers the 256-table limit twice over plus
   slack for modules waiting to be reclaimed.
3. Activation: a reload compiles every changed table into free names, never
   touching a published module. Only when all of them compile does it publish one
   new `:persistent_term` map of table to module, atomically switching every
   addition, change and deletion at once. If any table fails (compile error, no
   free name), nothing is published, the new modules return to the pool, and the
   previous set stays in force everywhere. The next poll retries it, so a node
   that ran out of names during a burst catches up once retired names are freed.
4. Reclamation: the modules the new map no longer uses are retired. Callers read the
   map once per event, inside the rule worker, whose events are bounded by the 1 s
   limit, so 30 s after retirement no caller can still hold one. Then the module is
   deleted and soft-purged (`:code.delete/1`, `:code.soft_purge/1`) and its name
   returns to the pool; if the soft purge fails, it is retried later, never forced.
5. After a Rules process restart, the pool is rebuilt from what is loaded: names in
   the published map stay in use, and any other loaded name is retired, not freed.
6. A reload recompiles only tables whose statements changed. Later, a table whose
   LOOKUPs read a TRACK that changed is recompiled with it.
7. Running a statement does not scan the row. At the first statement the runtime
   indexes the event's flattened row once: a trie of its keys by lowercase
   top-level object path, and each lowercase spelling's present keys in byte order.
   SET and UNSET then remove one subtree and a read is a lookup, so 1,000 statements
   on an event with 100,000 columns cost about the columns once, not their product.
   The trie is built at the first statement that applies, since it decodes every
   key, so an event whose statements all skip decodes none. (The first build scanned
   every key per applied SET and UNSET, and a read without an exact key walked that
   name's case variants, removed ones included.)

### Product spec impact

1. `overview.md`: replace "Guardian has no rule engine, alerting, or blocking" with
   ingest-time SET/UNSET rules stored as files; keep "no alerting".
2. `spec.md`: Purpose ("not transform events by rule"), a new section on rules
   (files, grammar, semantics, validation, storage, MCP tools), Ingestion (rules run
   before storage; `return_keys` returns null for missing keys), the MCP tool list,
   Non-features item 1 (rules exist; still no alerting, counters, or enrichment from
   services), configuration.
3. Also: `CLAUDE.md`, `lib/CLAUDE.md`, `lib/engine/CLAUDE.md`, `lib/ast/CLAUDE.md`,
   `lib/ast/node/CLAUDE.md` (LOOKUP line), `lib/web/CLAUDE.md`, `lib/web/mcp/CLAUDE.md`
   (drop "Do not add ... rule-management tools"), a new `lib/rules/CLAUDE.md`,
   `docs/architecture/system.md` (supervision tree, ingest path, a rules section),
   `docs/architecture/security.md` (rules can rewrite or drop any incoming field at
   the key holder's trust level; their cost on the ingest path; generated code from
   templates only; bounded atoms; S3 credentials in the secrets inventory with
   rotation: create a new token, update the settings, restart, revoke the old one;
   the lease race), `docs/reference/configuration.md`, `docs/reference/api.md`,
   `docs/guides/` (setting up an S3 store and switching to it), README.

### README example

A short section near the top: `logins/blocking.gsql` with two SETs (`is_blocked` from
a risk score, `is_suspicious` from an `RLIKE` on the lowercased message) and an
`UNSET password`, the JSON event sent with `return_keys`, the response, and a SELECT
with its result table showing the computed columns and no stored password.

## Open questions

Settled: 1 and 2 on their recommendations, with the alternatives removed; 3 on its
recommendation.

1. A statement that raises, or a batch over its heap or time limit. Recommended:
   fail closed, so the event is not stored and its result is an error naming the
   rule file and line. Failing open (store the event without that statement's
   effect) would store a password a failed `UNSET password WHERE ...` was meant to
   remove, and return no `is_blocked` to a client relying on it.
2. A table whose stored rules fail validation at load. Recommended: Guardian starts,
   events for that table fail with "rules for <table> are invalid (...); the event was
   not stored" until the rules are fixed through the MCP tools, and other tables run
   normally. The
   alternative, refusing startup, turns a hand edit or an upgrade that drops a
   function into a full outage that the MCP tools cannot fix, since they are down
   too. Running the table with no rules would silently skip its UNSETs.

3. Whole-set serialization across a partition. Recommended: accept the gap in
   "What this does not guarantee" above (a stalled writer or a very late request,
   both needing more than 60 s of delay), since a set it leaves invalid is caught
   at load and reported on the next write, and the default deployment is one
   machine. The alternative that closes it fully is one commit object that every
   write updates conditionally, which is a manifest.

## Switching an existing deployment to an S3 store

Written up generally in the guide: deploy the build first with the default local
folder (behavior unchanged), check the bucket credentials from the deployment's own
network before applying them, apply all bucket settings together in one restart,
and roll back by removing all of them together (removing only some refuses
startup). Copy any rules already in the local folder into the bucket first, or the
switch drops them. The local folder stays in place for rollback. The check
exercises the operations the lock depends on (create with `If-None-Match: *`, the
412 on a second create, `If-Match` overwrite) against the real store.

## Validation

1. Parser tests for each statement form, errors with positions, round trips through
   `to_source`, and contextual words still usable as column and table names.
2. Validation tests for every rejection above, a broken set repaired one file at a
   time, an unrelated table writable while another is invalid, identical duplicates deduplicated
   (including a self-reading `SET n = n + 1` in two files applying once),
   aggregates in WHERE, dependencies through WHERE.
3. Semantics tests: ordering, self-reads, UNSET after SET, case-insensitive reads
   and their tie-break, SET replacing an object, a list and a case variant, UNSET
   across case variants and nested paths, null for unknown fields, WHERE null,
   invalid rule outputs dropped, failing statements, a mixed batch where one event
   exceeds its limit (ordered outcomes, the rest stored), no event values in logs,
   built-in tables untouched.
4. Ingest tests over HTTP and MCP: computed fields in the response, unset fields
   absent from it, `return_keys` null for missing keys, nested results, stored rows
   queried back.
5. Store tests for the local folder, and for S3 against a fake S3 server in
   `libtest`: signatures checked against a known canonical request (prefix and
   continuation-token encoding, conditional headers), pagination, If-Match and
   If-None-Match, 412, a change between list and get, timeouts, oversized objects,
   and no secret in any log. No external services in tests.
6. Startup: unreachable store retried then refused, partial S3 settings refused, a
   table with an invalid stored set handled per open question 2.
7. Reload: an invalid change keeps the full prior set; a Rules restart keeps serving.
8. Compilation: repeated edits stay within the name pool; a reload that compiles one
   changed table and fails another leaves every published table on its old rules; a
   successful activation under concurrent ingest; a caller paused after reading the
   map while its table is updated or deleted still runs its old module.
9. Cluster tests with peer nodes (as the existing cluster tests do): a write reloads
   every node, concurrent writes serialize through the lock, an expired lease is
   taken over, a stale holder cannot release its successor's lock, an unknown save
   outcome leaves the lock held until expiry, a save refused with under 80 s left, local-folder writes refused with peers, polling catches a missed
   reload.
10. Full suite, `mix format`, warnings as errors.
