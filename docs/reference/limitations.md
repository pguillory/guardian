# Known limitations

1. No replication. A node's events live only on its own volume, so a lost volume loses
   them. On Fly, volume snapshots run daily (kept 14 days per `fly.example.toml`).
2. One principal. A full-access key holder can read and write everything; the
   insert-only ingest key can only send events, but can still read what its own
   ingests return and write any table, Guardian's built-in ones included.
3. Recent events can be lost in a crash. In-memory segments go to disk an hour after
   their first event by default, and queue or disk delays can stretch that. A hard
   crash loses what isn't on disk yet. A normal stop persists everything within the
   shutdown budget (about 110 s, after up to 10 s for the tunnel connector to drain;
   Fly's `kill_timeout` is 150 s).
4. Retention is fixed: persisted segments expire after 15 days.
5. A query covers only the nodes connected when it runs. A node that's down or still
   loading its segments is silently missing from results.
6. Memory isn't fully bounded. Results are capped at 100,000 rows and about 64 MiB, and
   strings that functions build at 64 KiB per value. Guardian kills any single
   query process whose Erlang heap passes 256 MiB, but that doesn't bound a query's
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
9. Rules: the write lock is a lease, not a guarantee. A rule write stalled for more
   than about a minute can still land after another and leave a rule set that the check
   would have refused; running nodes keep that table's last good rules, but a node
   that starts then rejects the table's events until the rules are fixed.
   Rules cost time on every event they run on (up to a second each), and nodes pick
   up a write within a minute if they missed its reload.
10. Counters are advisory and ephemeral. Buckets include the entire oldest
    intersecting interval (up to almost one extra bucket); distinct is approximate.
    Restarts, eviction, membership changes, partitions and uncertain writes can
    lose/split counts. Failed operations default and ingestion continues. A later
    rule/storage failure can leave increments behind, and unkeyed retries count
    again. The counter memory target covers resident rows only, excluding
    mailboxes, temporary copies and other VM memory. Housekeeping enforces it
    about every second, so writes can temporarily overshoot. A sampled
    earliest-expiry cutoff can evict every live bucket when expiries tie.
    High-cardinality BY values compete for that budget and can evict other groups.
    UNSET does not erase grouping keys or the state of value-keeping aggregates
    (arbitrary, min/max, the _by and _n forms) from counter memory.
    See the [rules guide](../guides/rules.md#counters-with-track-and-lookup).
