# url-parse-totality: URL functions never fail on a long port

## Problem

`URI.parse/1` doesn't validate a URL, but it turns the port's digits into an integer.
A port of more than about 1.26 million digits raises `system_limit`, and an event of
that size is storable (the JSON body limit is 8 MB). `url_scheme`, `url_host`,
`url_path` and `url_fragment` called `URI.parse/1` with nothing around it, so such a
value failed the query, or the event in an ingest rule, instead of giving a result.
`url_port` caught the error itself. Just under the limit the conversion succeeds but
takes about half a second to three quarters of a second per value (separate runs).

## Behavior after the change

1. The five `url_*` functions parse through one helper, `Guardian.Query.URL.parse/1`,
   which never raises.
2. A port of more than 20 digits (leading zeros count) is never converted. The other
   parts of the URL are read as before, so `url_host` of
   `http://example.com:<1.3 million nines>/p` is `example.com`, and `url_port` is null.
3. `url_port` was already null for any port over 65535. The one change is a port
   padded with leading zeros to 21 or more digits (`:000…080`), which gives null
   instead of 80.
4. Every other result is unchanged: the helper finds the port with `URI.parse/1`'s
   own regular expressions (Elixir 1.19), so it cuts exactly the digits that function
   would convert, and gives `URI.parse/1`'s result for every URL without a long port.

## Product spec impact

`docs/product/spec.md` section 7 adds a port written with more than 20 digits to the
values that give null, and the change restores its promise that functions give null
rather than fail. The function totality rule in `lib/guardian/query/function/CLAUDE.md`
names the helper.

## Validation

- `test/guardian/query/url_test.exs` compares the helper with `URI.parse/1` on every
  combination of up to three URL pieces (separators, brackets, line feeds, invalid
  UTF-8, non-ASCII digits, 20- and 21-digit runs) after five prefixes, and on a fixed
  sample of longer ones, where `URI.parse/1` itself can still convert the port; plus
  1.3-million-digit ports, including one with a line feed before an `@`.
- `test/guardian/query/totality_test.exs` gains a 21-digit port in the edge grid and
  runs every function on a 1.3-million-digit port alone (the grid takes every pair of
  values, too slow for a 1.3 MB one).
- Each `url_*` function's test reads such a URL.
- Measured: a 1.25-million-digit port fell from about 745 ms per value to about 66 ms.
  The cost is a second regular expression over the authority when it is longer than
  20 bytes: a pathological 8 MB authority (no `@`, all colons, an unclosed bracket)
  takes about 0.8 s against 0.4 s for `URI.parse/1` alone, most of a rule's 1-second
  event limit. Only the key holder can send such a value, and it fails that event, not
  the node.
