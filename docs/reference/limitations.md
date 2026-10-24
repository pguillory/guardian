# Known limitations

1. No replication. A node's events live only on its own volume, so a lost volume loses
   them. On Fly, volume snapshots run daily (kept 14 days per `fly.toml`).
2. One key, one principal. Every key holder can read and write everything.
3. Recent events can be lost in a crash. In-memory segments go to disk an hour after
   their first event by default, and queue or disk delays can stretch that. A hard
   crash loses what isn't on disk yet. A normal stop persists everything within the
   shutdown budget (about 110 s, after up to 10 s for the tunnel connector to drain;
   Fly's `kill_timeout` is 150 s).
4. Retention is fixed: persisted segments expire after 15 days.
5. A query covers only the nodes connected when it runs. A node that's down or still
   loading its segments is silently missing from results.
6. Memory isn't fully bounded. Results are capped at 100,000 rows and about 64 MiB, and
   string functions at 16 MiB per value. `GUARDIAN_QUERY_MAX_HEAP_MB` kills any single
   query process whose Erlang heap passes the limit, but that doesn't bound a query's
   total memory:
   - GROUP BY state lives in ETS, column data in native memory, and shared binaries
     aren't counted.
   - The check runs at garbage collection, so a process can overshoot.
   - Many processes can each reach the limit.
   A heavy query can still exhaust a machine. Size the machine with headroom. A large
   `ORDER BY` without `LIMIT` sorts in one process and can hit the heap limit; narrow
   it or add a `LIMIT`.
7. During a rolling deploy across machines running different releases, queries can
   fail until every machine runs the new one. Retry them.
8. Every machine running `guardian start` with the same cookie and DNS name joins the
   cluster and its query results.
