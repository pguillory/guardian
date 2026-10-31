# no-log-scrub-tests: stop testing what logs leave out

## Problem

`docs/changes/logging.md` stopped scrubbing logs, but two tests still guarded the one
exception it had kept, the API key in a log line:

1. `json_api_log_test`'s forced-500 test made a request crash on purpose, captured the
   log, and checked the key wasn't in it. CONTRIBUTING.md's logging rules don't allow
   a test that crashes a process on purpose.
2. `config_test` failed if `config/config.exs` gave production a log formatter or
   handler, which existed only to keep Bandit's conn metadata, which holds the key,
   unprinted.

## Change

1. Both tests are deleted. Preston decided logs aren't scrubbed and aren't tested for
   what they leave out.
2. The rest of `json_api_log_test` becomes `json_api_listener_test`, async, with no
   log capture: a one-byte-chunked JSON batch and a malformed body split after
   `Expect: 100-continue`, both on the real HTTP listener. Each checks the response
   only: their log assertions (no crash in the chunked test, the body not logged in
   the Expect test) go too. The chunked test uses a unique table.
3. Kept, as Preston decided earlier: both routers drop every `x-api-key` header from
   the conn once the key passes (`Guardian.Web.Auth.drop_api_key/1`, covered by
   `auth_routes_test` and the MCP `key_drop_test`). That is about what later plugs and
   handlers hold, not about logs.
4. CONTRIBUTING.md's logging rule 4 and `docs/architecture/security.md` say so. They
   still state the fact: Bandit's own conn keeps the header as error-line metadata,
   which the default formatter doesn't print, and a formatter that printed `conn` or
   `crash_reason` would print the key.

Coverage lost: the forced-500 test was the only test of the JSON API's catch-all
error path, a bare `{"status": 500}` for an unexpected failure. `json_api_test` still
covers the 400, 413 and 415 answers and transport errors.

No log-scrubbing code was left to remove; `Guardian.Web.MCP.LogFilter` was already
gone.

## Product spec impact

None.

## Validation

`json_api_listener_test` passes async. Nothing about runtime behavior changed.
