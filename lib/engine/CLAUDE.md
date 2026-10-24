# Engine Subsystem

Engine is Guardian's event-ingestion boundary.

- `Engine.ingest_event/2` drops values that are unsafe for Storage, appends the event,
  and returns the stored event. It validates the flattened event, so invalid values
  nested inside objects and fields whose flattened key exceeds 250 bytes are dropped
  individually. The validated flat row is stored with `Storage.append_flattened/2`
  (never unflattened and re-flattened, which cannot rebuild every shape). Events with
  nothing dropped are returned unchanged.
- `Engine.ingest_events/2` processes events independently and returns ordered
  `{:ok, event}` or `{:error, message}` outcomes, continuing after each failure.
  Non-object events fail before storage. Unexpected failures before storage say the
  event was not stored; failures after storage starts say it may have been stored.
  An explicit storage refusal says it was not stored. A failure's kind and an
  argument-free stack trace go to Logger.
  `Engine.ingest_event/2` retains its raising behavior for internal callers.
- Both reject table names that SQL cannot address with `Engine.InvalidTableNameError`
  before writing: names must match `[a-z_][a-z0-9_]*`, be at most 64 bytes (segment
  filenames must fit the filesystem's 255-byte limit), and must not be a tokenizer
  keyword, `null`/`true`/`false`, `current_date`/`current_timestamp`, or `schema`.
  This also keeps names safe in segment filenames. If the SQL tokenizer's identifier
  rules or reserved words change, update this rule to match. Keep this check at the
  Engine boundary, not in Storage.

`ingest_events/2` runs the table's rules when it has any (`Rules.lookup/1`): it
captures private arrival coordinates before validating each event, hands valid rows
and their metadata to `Rules.run_with_metadata/2` (a worker, one outcome per row),
validates the values the rules produced the same way, and stores the
result. Metadata is never caller-controlled, a row field or stored automatically.
The whole batch is prepared before execution; later rows can therefore reach rules
after their counter window expires. The reported event is built from the row after
rules; Engine's shortcut of reporting the original event applies only when the rules
changed nothing. A rule
failure is that event's `{:error, message}` and it is not stored. `ingest_event/2`
and the `log_event` writers (Guardian's built-in tables) never run rules. Rule
compilation and management live in `lib/rules`, not here. Keep Engine free of
external service dependencies. HTTP `/api/json/send_events` and MCP
`send_events` are the API ingest paths. Guardian's own built-in tables are written
through `Engine.log_event/2` and `Engine.try_log_event/2`: `SystemStats`, request
logging and query parse errors use `try_log_event/2` and log only its failure kind;
`Web.QueryParseErrors` also names its own caught failures with
`Engine.failure_kind/3`. An ingestion crash is logged the same way, by its kind and
a stack trace without arguments; never log an exception's message or a stack trace
with arguments here, since both can carry event values. SQL queries are read-only.
