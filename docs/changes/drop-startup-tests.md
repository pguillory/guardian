# drop-startup-tests: no tests of startup refusing bad settings

## Problem

`test/guardian/config/runtime_test.exs` read `config/runtime.exs` under changed OS
environment variables, so its module couldn't run async, and most of what it checked
was startup refusing a missing or bad variable. Preston decided that is low value and
not worth testing. `test/guardian/storage/persisted_segments_settings_test.exs` held
one test of the same kind: an invalid persisted segment cache window
(`persisted_segment_cache_ms`) stops the persister from starting.

## Change

Both files are deleted. Startup code is unchanged: `config/runtime.exs` and
`Guardian.Storage.PersistedSegments` still refuse what they refused.

`runtime_test` covered more than refusals, and all of it goes with the file: the
production authentication config loading from the admin key, the optional ingest key,
a dev Mix run generating and printing a random admin key, `GUARDIAN_DATA_DIR` creating
the segment directory (and the Fly volume checks), DNS discovery set only with a query,
`mutable_segment_max_age_ms` and HTTP port overrides, Storage using the configured data
directory for its segments, removed variables being ignored
(`GUARDIAN_API_KEY`, `GUARDIAN_USER_ID`, `GUARDIAN_ALLOW_QUERY_API_KEY`,
`GUARDIAN_QUERY_MAX_HEAP_MB`, including that runtime config cannot set
`:query_max_heap_mb`), and `GUARDIAN_COUNTER_MEMORY_MB` parsing and reaching
`Guardian.Counters.Store`.

With no test left changing the OS environment, CONTRIBUTING.md no longer lists it as
a reason a module can't be async.

Counter budgets are not part of this. Their tests put budget settings in the
application env and stay synchronous, an open item under `test-settings-as-data` in
TODO.md, with S3 timeouts.

## Product spec impact

None.

## Validation

The default suite passes without them. No other test used the OS environment or
`persisted_segment_cache_ms`.
