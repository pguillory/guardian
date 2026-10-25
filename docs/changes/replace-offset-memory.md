# replace-offset-memory: bound the match offsets of one replace() value

## Problem

`replace()` asks `:re` for every match of a value at once (`:global`), then checks
the exact result size against the 16 MiB string limit and splices. `:re` builds that
list on the calling process's heap, and a value can have about two matches per
character (`(?:|a)` matches 2n + 1 times in n characters). With the query heap
limit off (`GUARDIAN_QUERY_MAX_HEAP_MB=0`),
nothing bounded the list: measured on OTP 28, `x*` on a 1 MB value grew the VM by
about 0.5 GB and on 4 MB by 1.7 GB, while the result itself (8 MB) was well under the
string limit.

Streaming the matches instead, one `:re.run` per match from an offset, would keep no
list, but it is quadratic for UTF-8 patterns: PCRE validates the subject from the
offset to its end on every call, and `:re` has no option to skip that (40,000
characters of empty matches took a second, 100,000 took 7 s, where `:global` takes
0.15 s for 100,000). `re:replace` and `re:split` are built on `:global` too.

## Behavior after the change

1. A value up to 16 KiB is replaced in the calling process, as before. It has at most
   about 33,000 matches.
2. A larger value is replaced in a helper process spawned with its own heap cap: the
   query heap limit when it is set, or 256 MiB when it is 0. A helper killed by its cap
   fails the query with "regular expression matched too many times in one value ...",
   naming the cap and suggesting a pattern that matches less often (for example one
   that cannot match the empty string). With `x*`, a 256 MiB cap allows about 600,000
   matches on one value and 64 MiB about 200,000.
3. Everything else is unchanged: one `:re.run` with `:global` (leftmost-first, Perl's
   empty-match rules), a literal replacement, null for a value that is not valid UTF-8,
   and the same errors for `\C` splits, the backtracking limit and the 16 MiB string
   limit, raised again in the caller exactly as the helper raised them.
4. The helper is monitored, not linked: a link would carry its heap kill to the
   caller. Its first act is to start a watcher that kills it when the caller dies (a
   query stopped at its time limit), so no helper outlives its query, even if the
   caller dies as the helper starts.
5. The splice appends to one binary instead of collecting a list of slices, and the
   boundary check and size count are one pass over the matches, so the helper's budget
   goes to `:re`'s list.

The cap is a heap budget checked at garbage collection, so it can overshoot somewhat;
it counts neither PCRE's native backtracking frames (bounded by the depth limit and the
group cap) nor the result binary (bounded by the string limit).

## Product spec impact

`docs/product/spec.md` item 5 gains one sentence: a `replace` whose pattern matches one
value too many times fails the query with a message saying so. Item 8 gains one: a
`replace` on a value over 16 KiB runs in a helper with the query heap limit, or
256 MiB when it is `0`. `overview.md`: none.

## Validation

- `test/query/regex_memory_test.exs` (not async, since it changes the heap limit):
  `x*` on a 4 MB value with the heap limit off fails with the new error at 256 MiB;
  `.` on a 1 MB value fails at a 32 MiB setting while a modest large value succeeds;
  the cap follows the setting (0, unset, 32); an ingested 1 MB value queried with
  `x*` through `run_sql` fails with `Guardian.Query.Error` and the next query works; a helper
  dies when its caller is killed, both mid-replace and as the helper starts (a trace of
  the caller's spawns gives the helper's pid).
- `test/query/function/replace_test.exs`: values over 16 KiB give the same results as
  `:re.replace` for quantified, empty-matching, alternating, Unicode and one-character
  patterns, and the same `\C`, non-UTF-8 and string-limit outcomes as small values.
  The existing 200,000-character backtracking test now runs through the helper.
- The full `mix test` suite passes.
