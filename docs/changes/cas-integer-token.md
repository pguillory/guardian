# cas-integer-token: one random integer CAS token, and memcached's add and cas

Status: complete.

## Problem

`Guardian.Counters.Store` tokens were `{table_reference, version}`, where the version
came from `System.unique_integer/1`. Only Store looked inside them, and the table
reference existed to reject tokens from another table. CAS also created keys through a
`:missing` token, and it took a TTL that it ignored on existing rows.

## Behavior

1. A token is one integer, memcached-style: the row's version, 59 random bits from
   `:crypto.strong_rand_bytes/1`, always an Erlang small integer. A write stamps a new
   one. No generation, clock or unique integer.
2. `Store.add/5` creates a key only if absent: `:ok` or `{:error, :not_stored}`, replacing
   an expired row. `{:add, key, value, ttl}` joins batches, Transport routes it, and its
   anchored expiry works like incr's.
3. `Store.cas/6` only applies to an existing row: `:ok`, `{:error, :exists}` for a live row
   with another token (it replaces `{:error, :conflict}`), or `:not_found` for no live row.
   `:missing` and the reference forms are gone: a non-integer token is
   `{:error, :invalid_request}`. Which of exists and not_found comes back is an expiry read
   after the failed swap, not atomic with it. Both mean nothing was stored; re-read.
4. Cas sets the row's expiry to `now + ttl`, as memcached's does. Counter callers pass the
   same anchored bucket expiry on every write, so the row ends at the same bucket end, give
   or take transit, and across nodes clock skew; the last writer's reading now counts rather
   than the first's. Incr still retains the expiry.
5. `KeyMachines.merge` writes with add after a missing gets, otherwise cas. All three lost
   races (add `:not_stored`, cas `:exists`, cas `:not_found`) share its three attempts and
   re-read. A last attempt lost to cas `:not_found` finishes as `{:error, :not_found}`,
   because Execution reads a bare `:not_found` as a healthy missing bucket.
6. Budget treats `:exists` and `:not_stored` as healthy, as it did `:conflict`.

Incr keeps creating a missing key, unlike memcached's: that is what makes one count one
atomic operation. Store gains no set, replace, delete or decr, since nothing calls them.

## What the table reference protected

A token from before a store restart or table recreation could never match. Now it matches
only if the same key's current version equals it by chance: 1 in 2^59 per attempt, and the
same for a token from another store or an old version of one key recurring. The worst case
is overwriting the updates since the read, in an advisory counter, and such a token has to survive a restart inside
one event's 100 ms counter phase to exist at all.

## Random source

The figures are from scratch benchmarks on the development machine. Today's
`System.unique_integer/1` costs about 13 ns, `:rand.uniform(2^58)` about 55 ns and
`:crypto.strong_rand_bytes(8)` about 430 ns. One write in a fresh process, like Transport's
per-pipeline worker, took 1.42 us with unique_integer and 1.80 us with crypto.

`:rand` is the wrong choice despite costing less per draw. It seeds each process
automatically, and the first draw depends mostly on bits that barely change across
processes started together. Across 100,000 fresh processes, first draws gave 7 to 16
duplicates, about one pair in 2^29, while crypto gave none. Every Transport worker is a
fresh process.

Hashing or comparing the value were rejected: states can reach the memory budget in size,
and a match spec cannot compute a hash.

## Rolling deploys

No compatibility path. Clusters run one build (`lib/guardian/AGENTS.md`). A token returns to
the owner node that issued it, since the event's membership snapshot fixes the owner, and
callers treat it as opaque. Add does cross nodes: in a mixed cluster an old caller's `:missing`
cas on a new owner and a new caller's add on an old owner are `:invalid_request`, an old
caller gives up on `:exists` and charges it as a failed call, and a new caller does the same on
an old owner's `:conflict`. Those fail open per statement. An old caller's cas answered bare
`:not_found` undercounts quietly instead, since the old Execution reads it as a missing bucket.

## Product spec impact

None. "Only definite CAS conflicts retry" stays true at the product level, where lost adds
and cas on a vanished row are the same kind of contention.
