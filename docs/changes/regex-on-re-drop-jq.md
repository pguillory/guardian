# regex-on-re-drop-jq: regular expressions on :re, no jq()

## Problem

`replace()` with a regular expression whose matches grow or overlap, such as
`replace(path, '[0-9]+', ':id')`, aborted the whole Erlang VM. Guardian compiled the
pattern with Hyperscan's `HS_FLAG_SOM_LEFTMOST` and called the hyperscan 0.1.5 NIF's
`replace`. Hyperscan reports every end of a growing match ((3,4), (3,5), (3,6) for
"/u/123"), and the NIF's callback asserts that each match starts after the previous
one ended (`assert(from >= context->last_to)`). The package builds without `NDEBUG`,
so the assert is live in release builds. Any key holder could take a node down with
one query, and probably every node of a cluster, since queries fan out. Reproduced in
a throwaway VM: the assertion message, then exit status 134. Hyperscan has no
leftmost, non-overlapping match mode, and the NIF exposes no match offsets, so fixing
it in place would have meant forking the package.

Hyperscan (x86-64 only, a system library) and jq (libjq and a sandboxed worker
process) were also the two native dependencies that made Guardian hard to install.
No known caller used `RLIKE`, `replace()` or `jq()`.

## Behavior after the change

1. `RLIKE` and `replace()` use Perl-compatible regular expressions through Erlang's
   `:re` (`Query.Regex`), which also validates patterns at parse time.
   - Values that are valid UTF-8 match by character. `\w`, `\d`, `\s`, `\b` and
     POSIX classes stay ASCII by default (inline `(*UCP)` changes that). `(?i)` folds non-ASCII letters too. A value that is not
     valid UTF-8 gives null, as a non-string does.
   - `replace()` is global and leftmost-first: at each position the first alternative
     that matches wins (`a|ab` on "ab" gives "Xb"). The replacement is literal.
     Patterns that can match empty are now accepted, with Perl's rules:
     `replace('abc', 'x*', '-')` is "-a-b-c-". A match that would split a character
     (only `\C` can produce one) fails the query.
   - The 16 MiB string limit counts the exact result size. The old worst-case
     estimate no longer holds once empty matches are allowed: `(?:|a)` matches 2n + 1
     times in n characters.
   - Every run has `match_limit` 1,000,000 and `match_limit_recursion` 10,000, and a
     pattern may have at most 32 capturing groups (a parse error otherwise). PCRE2's
     backtracking frames live in native memory outside the heap limit and grow with
     the group count; without these bounds, code review measured a pattern of
     hundreds of empty groups taking over 1 GB on one value. A pattern that
     backtracks past the limits fails the query with "regular expression too complex
     ...", a 400 from the JSON API and an error from MCP.
2. `jq()` is gone. Calling it is a parse error explaining that nested fields of
   ingested JSON objects are already columns (`payload.user.id`). A column named `jq`
   still parses.
3. The image needs no system libraries beyond OpenSSL and libstdc++, and nothing in
   the build is x86-only any more. cloudflared now comes from one pinned, checksummed
   stage per architecture (both hashes checked against the release notes), so
   linux/arm64 should build. That is untested so far (TODO.md ci-arm64-image).

Differences users could notice compared with Hyperscan:
- RLIKE is about 3 to 10 times slower: 2.5 to 10 µs a row on 89-byte strings,
  against under 1.2 µs, on 200,000 rows.
- `.` and `.{n}` count characters, not bytes.
- PCRE syntax that Hyperscan rejected is now accepted: backreferences, lookaround,
  atomic groups, and patterns that can match empty.

## Product spec impact

`docs/product/spec.md`:
- `RLIKE` is described as Perl-compatible instead of Hyperscan.
- The scalar function count goes from 61 to 60, and the `jq()` paragraph is replaced
  by its removal.
- One paragraph gives the regular expression semantics and the backtracking-limit
  error.

`docs/product/overview.md` drops Hyperscan and jq from the native code it lists.

## Validation

- Tests: `replace()` with quantified, lazy, alternating, overlapping, adjacent and
  empty-matching patterns, anchors, `\b`, a literal replacement with `&`, `\1`, `$1`
  and `\`, Unicode, non-UTF-8 values (including `\x{100}` and `(*UTF)` patterns),
  `\C` splits, the exact-size limit, and catastrophic backtracking. `RLIKE` and
  `NOT RLIKE` cover the same ground. Parser tests cover the jq() message and a column
  named `jq`. The pipeline cleanup test now fails a query with the backtracking
  limit instead of a jq error.
- The full `mix test` suite passes.
- Docker builds: not run locally (no container runtime on the development machine).
  CI's docker job builds amd64; arm64 is untested.
