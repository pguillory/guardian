# Guardian query language

Guardian is a schemaless event store. Each table holds JSON events, and the `query`
tool runs one SQL-like statement over them. Queries are read-only; ingest with the
`send_events` tool.

## Statements

```sql
SHOW TABLES
```

```sql
DESC web_requests
```

DESC lists a table's column names. It shows no types, because columns are untyped.

```text
SELECT expr [AS alias], ... [FROM table] [WHERE cond] [GROUP BY expr, ...] [HAVING cond] [ORDER BY expr [ASC|DESC], ...] [LIMIT n]
```

- `FROM` names one table. Without `FROM`, SELECT evaluates constant expressions.
- `SELECT *` expands to every column of the table.
- `LIMIT` takes an integer literal only.
- A query may return at most 100,000 rows and about 64 MiB; a larger result fails
  with an error asking for a LIMIT, a WHERE, or GROUP BY (it is never cut short).
  Rows scanned or aggregated don't count, so `count()` over a huge table is fine.
  ORDER BY with a LIMIT over 100,000 is refused.
- Repeating a clause is an error, except `WHERE`: repeated WHERE clauses are ANDed.

`LET name = expr` substitutes `expr` for `name` in the statement that follows, separated
by `;`. The tool runs exactly one statement after LETs are applied:

```sql
LET slow = response_time_ms > 1000; SELECT path, count() FROM web_responses WHERE slow GROUP BY path
```

The virtual table `schema` has one row per table and column, with the columns `table`,
`key`, `count`, `null_count`, `false_count`, `true_count`, `int_count`, `float_count`,
and `string_count`. SHOW TABLES and DESC are shorthand for queries on it.

## Not supported

- `UNION`, `JOIN`, and subqueries. Each query reads one table.
- `DISTINCT`. Use `GROUP BY`, or the `count_distinct(x)` aggregate.
- `OFFSET`.
- Quoted identifiers (no backticks or double quotes), so a column named after a keyword
  such as `desc`, `end`, or `values` can't be referenced on its own.
- `INSERT`, `DELETE`, `UPDATE`, and `DESCRIBE` (use `DESC`).

## Data model

Columns are untyped. One column can hold integers, floats, strings, booleans, nulls,
and lists in different events. A column absent from an event is null. Ordinary
comparisons with null (`=`, `!=`, `<`, ...) are null, so such rows drop out of `WHERE`;
test for missing values with `x IS null`, `x IS NOT null`, or `<=>`. Use `type(x)` to
see what a value is: `'null'`, `'boolean'`, `'integer'`, `'float'`, `'string'`, or, for
a list, a list of the types it contains.

Nested JSON objects are flattened into dotted column names: `{"user": {"name": "Bob"}}`
is the column `user.name`. A list of objects adds a dot for each list level:
`{"users": [{"name": "Bob"}, {"name": "Joe"}]}` gives `users..name`, which returns
`["Bob", "Joe"]`. Lists of scalars are stored as list values. Column names match
ignoring case.

## Timestamps

Timestamps are plain strings. By convention, not enforcement, they are UTC in
`YYYY-MM-DD HH:MM:SS` format, as written by Guardian's own tables (`system_stats`,
`web_requests`, `web_responses`, `query_parse_errors`, `queries`) and returned by `now()`. When every value uses that
format, string comparison and sorting are chronological, so time ranges work directly:

```sql
SELECT count() FROM web_requests WHERE timestamp >= '2026-10-01 00:00:00' AND timestamp < '2026-10-02 00:00:00'
```

```sql
SELECT path, count() FROM web_requests WHERE timestamp > date_sub(now(), INTERVAL 1 HOUR) GROUP BY path
```

Time arithmetic (`date_add`/`adddate`, `date_sub`/`subdate`, timestamp `+` or `-`
seconds, `to_seconds`/`unix_timestamp`) accepts only UTC `YYYY-MM-DD HH:MM:SS`:
exactly 19 bytes with a space. Numeric offsets (`+02:00`, `-0500`, `+02`, even
`+00:00`) give null, with no conversion. A `T` separator, trailing `Z`, fractional
seconds and other formats also give null. Calendar fields must be valid and years
must be 0000 to 9999; arithmetic outside that range gives null. Timestamp results
use the same UTC format, and `to_seconds` gives seconds since 1970 UTC. `date(ts)`
and `format_timestamp` also require the space-separated format without a suffix.
Comparisons and sorting compare the strings as they are.

## Expressions

- Literals: integers, floats (`1.5`, `1.`, and with an exponent `1e20`, `2.5E-3`),
  `'strings'`, `true`, `false`, `null`, and lists `[1, 2, 3]`. In strings, a
  backslash escapes: `\'`, `\\`, `\/`, `\b`, `\f`, `\n`, `\r`, `\t`, and `\uXXXX`
  (four hex digits; a character outside the Basic Multilingual Plane is a surrogate
  pair, as in JSON).
- Integer literals run from 0 to 9223372036854775807 (64-bit; minus is an operator,
  not part of the literal). A larger one, anywhere including `LIMIT` and
  `INTERVAL n UNIT`, is the parse error "Number out of range", like a float too large
  to represent (`1e400`). Write the smallest 64-bit integer as
  `-9223372036854775807 - 1`.
- Arithmetic: `+ - * /`, unary `-`. String concatenation: `||`. Integers are 64-bit
  and wrap around on overflow (`9223372036854775807 + 1` is `-9223372036854775808`).
- Comparison: `= != < <= > >=`, `<=>` (null-safe equal), `IS`, `IS NOT`.
- Logic: `AND`, `OR`, `NOT`.
- `x BETWEEN a AND b`.
- `x IN [a, b, c]`. The list uses square brackets; parentheses are not a list.
- `LIKE` and `ILIKE` (case-insensitive), with `%` matching any run of characters and
  `_` exactly one (a UTF-8 character, or a byte if either side isn't valid UTF-8); no
  escape character. A pattern of more than 1,000 characters besides `%` gives null.
  Matching never backtracks: its time grows linearly with the value. `RLIKE` takes a
  regular expression string literal and is true when it matches anywhere in the
  value. Each has a `NOT` form. See "Regular expressions" below.
- `CASE WHEN cond THEN x [WHEN ...] [ELSE y] END` and `CASE x WHEN v THEN y ... END`.
- `INTERVAL n SECOND|MINUTE|HOUR|DAY|WEEK` is a number of seconds.
- `current_date` and `current_timestamp` work without parentheses.
- Precedence, tightest first: `* /`; `+ - ||`; comparisons, `IS [NOT]`,
  `[NOT] LIKE|ILIKE|RLIKE`, `IN`; `BETWEEN`; `NOT`; `AND`; `OR`. Binary operators
  of equal precedence group left to right. `NOT a = b` means `NOT (a = b)`, and
  `NOT a AND b` means `(NOT a) AND b`. Unary `-` binds tighter than comparisons.

## Aggregates

Aggregates make a query grouped; with no GROUP BY, the whole table is one group.

- `count()` or `count(*)`: number of rows. `count(x)`: rows where x is not null.
- `count_distinct(x)`: number of distinct non-null values (approximate, using
  HyperLogLog)
- `count_if(cond)`
- `sum(x)`, `avg(x)`, `min(x)`, `max(x)`
- `min_by(x, key)`, `max_by(x, key)`: x from the row with the smallest or largest key;
  rows whose key is null are skipped (x itself may be null)
- `min_n(x, n)`, `max_n(x, n)`, `min_n_by(x, key, n)`, `max_n_by(x, key, n)`: lists of
  the n smallest or largest, skipping null values (`min_n`, `max_n`) or rows whose key
  is null (the `_by` forms). n must be a non-negative integer, the same for every row
  of a group; use a constant.
- `arbitrary(x)`: any one value; `all(cond)`: true when cond is true for every row
- `stddev(x)`, `stddev_samp(x)`, `stddev_pop(x)`, `variance(x)`, `var_samp(x)`,
  `var_pop(x)`

`sum`, `avg`, and the variance and standard deviation aggregates skip values that are
not numbers (null, strings, booleans, lists); a group whose values include no numbers
gives null (`sum` over no rows at all gives 0.0). An integer `sum` wraps around like
`+`; a float `sum`, `avg`, variance or standard deviation that overflows is null.

```sql
SELECT status, count(), avg(response_time_ms) FROM web_responses GROUP BY status HAVING count() > 10 ORDER BY count() DESC LIMIT 10
```

## Scalar functions

Numeric functions and operators never fail the query. A result with no good value is
null, never NaN or infinity: division or `mod` by zero, `sqrt` of a negative, a
logarithm of zero or less, a float too large to represent (`1e308 * 10`), `round`,
`ceil` or `floor` of a float outside 64-bit integers, an `INTERVAL` outside them,
date arithmetic outside years 0000 to 9999, and a list nested deeper than a list of
lists.

Functions return null when an argument has the wrong type.

A string a function builds is cut to 64 KiB, at a character boundary: the results of
`concat`, `||`, `lpad` and `rpad` when they pad, `replace`, `to_string` of a
non-string, `lower`, `upper`, `normalize` and `format_timestamp`. `replace`, `lower`,
`upper` and `normalize` cut even a value they don't lengthen. Functions that return an
input or part of one (`to_string` of a string, `substr`, the trims, `if`,
`coalesce`) are not cut.

- Math: `abs(x)`, `ceil(x)`, `floor(x)`, `round(x)`, `div(a, b)`, `mod(a, b)`,
  `power(a, b)`, `sqrt(x)`, `exp(x)`, `log(x)`, `log2(x)`, `log10(x)`,
  `factorial(n)` (null above 20), `pi()`, `random()`, `random(seed)`
- Strings: `concat(a, b, ...)` (2 to 9 arguments), `length(s)`, `lower(s)`,
  `upper(s)`, `trim(s)`, `ltrim(s)`, `rtrim(s)`, `lpad(s, n)`, `rpad(s, n)`,
  `reverse(s)`, `substr(s, start)`, `substr(s, start, count)` (start is 1-based),
  `replace(s, 'regex', replacement)`, `normalize(s)`, `normalize(s, 'NFC')` (also
  NFD, NFKC, NFKD). `concat` and `||` treat null as the empty string and turn any
  other value into its string form, as `to_string` does.
- Conditionals: `if(cond, x)`, `if(cond, x, y)`, `coalesce(a, ...)` (1 to 4 arguments)
- Types: `type(x)`; `to_string(x)` gives x's string form: a string as it is, an
  integer in decimal, a float in its shortest round-trip form (`1.0e300`), `true` or
  `false`, a list as compact JSON-style text (`[1,null,"a",[2.5]]`, invalid UTF-8 in
  its strings as U+FFFD), and null for null. `to_boolean(x)` returns x when it is a
  boolean, else null
- Time: `now()`, `current_timestamp`, `date()`, `curdate()`, `current_date` (today as
  `YYYY-MM-DD`), `date(ts)` (the date part of a timestamp), `date_add(ts, seconds)`,
  `adddate(ts, seconds)`, `date_sub(ts, seconds)`, `subdate(ts, seconds)`,
  `to_seconds(ts)`, `unix_timestamp(ts)` (seconds since 1970), and
  `format_timestamp(ts, 'yyyy-MM-dd hh:mm')`
  (patterns yyyy, y, MMMM, MMM, MM, M, dd, d, hh, h, mm, m, ss, s, AM, am; hours are
  always 24-hour)
- Hashes and IDs: `md5(s)`, `sha1(s)`, `sha256(s)`, `sha512(s)`, `generate_uuid()`
- URLs and email: `url_scheme(u)`, `url_host(u)`, `url_port(u)`, `url_path(u)`,
  `url_fragment(u)`, `email_username(e)`, `email_domain(e)`, `ip_to_integer(ip)` (an IPv4
  address; null for anything else, including a string over 64 bytes)
- Other: `cosine_similarity(a, b)` compares two numeric lists
- There is no `jq()`: calling it is a parse error. Nested fields of ingested JSON
  objects are already columns (`payload.user.id`; see "Data model").

### Regular expressions

`RLIKE` and `replace` take Perl-compatible regular expressions (PCRE, through Erlang's
`:re`) as string literals; an invalid pattern is a parse error.

- In a string literal a backslash is itself an escape, so write the regex `\d+` as
  `'\\d+'`.
- Values match by character, not byte: `.` matches `é` whole. `\w`, `\d`, `\s`, `\b`
  and POSIX classes such as `[[:alpha:]]` are ASCII-only unless the pattern starts
  with `(*UCP)`. A value that is not valid
  UTF-8 gives null.
- Matching is case-sensitive; `(?i)` makes it case-insensitive, including for
  non-ASCII letters. `^` and `$` match at the start and end of the value (`$` also
  before a final newline); `(?m)` makes them match at every line. `(?s)` lets `.`
  match a newline.
- `replace(s, 'regex', replacement)` replaces every non-overlapping match, scanning
  left to right. At each position the first alternative that matches wins, and
  quantifiers are greedy unless written lazy (`+?`): `replace('ab', 'a|ab', 'X')` is
  `'Xb'`. The replacement is inserted literally: `&`, `\1` and `$1` have no special
  meaning. A pattern that can match the empty string inserts the replacement at each
  empty match, as Perl does: `replace('abc', 'x*', '-')` is `'-a-b-c-'`.
- `replace` is null if a match would split a character, which only `\C` can do.
  It is also null on a value with too many matches to hold (millions of empty
  matches of a pattern like `x*` on a large value).
- A pattern may have at most 32 capturing groups; use `(?:...)` for the rest.
- A pattern that backtracks too much on some value, such as `(a+)+$` against a long
  run of `a`s, or a repeated group over a very long value (`^(?:\w+\s)*$` over
  20,000 words), gives null on that value: `RLIKE` and `NOT RLIKE` are both null, so
  WHERE drops the row, and `replace` is null. Simplify the pattern, for example by
  removing nested quantifiers.
