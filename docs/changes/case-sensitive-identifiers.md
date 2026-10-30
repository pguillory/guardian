# Case-sensitive identifiers and flat field names

Status: complete.

Field, column and table identifiers keep the case they were written in and match
exactly, in queries and rules. Rules treat a field name as one flat column: SET and
UNSET act on exactly the named column, never on the columns beneath it. Stored data
is flat, so a name is just a string. Case folding cost a resolver pass, an ambiguity
error and, with subtree removal, an index on every rule run.

Product spec impact: `docs/product/spec.md` section 5 item 4 (`send_events` result),
5.1.2 items 1 to 4, 5.1.3 items 1 and 3, 6.2, section 7 items 1 and 7, and the mentions
of ambiguous columns in the `query_parse_errors` and `queries` descriptions. `docs/product/overview.md`: none.

## Behavior

1. Identifiers keep their written case. `userId` and `userid` are two columns. A
   query in another case than the stored one reads a missing column: null, with no
   error, like any other missing column. The ambiguous-column error is gone.
2. Keywords stay case-insensitive: the tokenizer's keywords, `true`, `false`, `null`,
   `CURRENT_DATE`, `CURRENT_TIMESTAMP`, and the rule words `SET`, `UNSET`, `TRACK`,
   `LOOKUP`, `LAST`, which are matched by position.
3. Function and aggregate names stay case-insensitive: `COUNT(*)` is `count(*)`,
   and labels show the lowercase name. Only field, column and table names are exact.
4. Aliases and `LET name = expr` names match exactly and keep their case: `AS Total` labels the
   column `Total`, and `ORDER BY total` does not find it.
5. Table names stay lowercase-only, as `Guardian.Engine.valid_table_name?/1` already
   requires. `FROM Events` names no table, and a rule's `LOOKUP x = c FROM Events` is
   invalid.
6. A rule reads the row's key of exactly the name it uses: `card` is null when an
   event holds only `card.number`.
7. SET, TRACK and LOOKUP write one column, in the statement's spelling, and remove
   nothing. `user` and `user.name` are different columns and can both be stored.
8. `UNSET x` removes exactly the column `x`. `UNSET card` leaves `card.number`;
   removing nested values means naming each one (`UNSET card.number`,
   `UNSET users..email`), in each spelling that can occur. UNSET therefore now accepts
   list paths. A rule can name only columns made of letters, digits, underscores and
   dots, as a query can: `headers.x-api-key`, a key with a space or a quoted key can
   be neither read nor removed by a rule, and a key not known in advance cannot be
   named. Such a value is stored unless the sender leaves it out.
9. A rule's dependencies are exact names: `SET a = b.x` does not depend on `SET b`.
10. A row holding both `user` and `user.name` cannot be rebuilt as one JSON value, so
    `send_events` omits the top-level field from its result, as for other shapes it
    cannot rebuild: `return_keys: ["user"]` returns null. The stored row keeps both.
    A sender can cause this for a rule's output by sending a nested key under its name,
    so a caller must not treat a null output as a decision.

## Design

1. `Guardian.AST.Tokenizer`: identifiers keep their raw text. `Parser`: rule words
   compare through a downcased copy of the word at their position. `CURRENT_DATE`
   and `CURRENT_TIMESTAMP` keep their existing downcased comparison, and a name before
   `(` is downcased in the one place function calls parse. The refusal of list paths
   in UNSET goes.
2. `Guardian.Query.Resolver`: drop column-name resolution and
   `Guardian.Query.AmbiguousColumnError`. Labels no longer need LET names to skip;
   SELECT * still expands from the merged schema.
3. `Guardian.Rules.RowIndex` is deleted. `Guardian.Rules.Runtime` threads the row
   map itself, which is also the read context: writes are `Map.put/3`, UNSET is
   `Map.delete/2`. UNSETs keep their order and levels.
4. `Guardian.Rules.DependencyGraph` compares exact names; `top_level/1` goes.

## Compatibility

1. Stored segments keep their stored case and need no migration. Queries must use
   that case.
2. Rule source is re-parsed at boot, so on upgrade a rule starts to mean exactly what
   it says: `SET isBlocked` stores `isBlocked`; a `LOOKUP` whose case differs from its
   TRACK no longer resolves (the rule set is invalid and that table's events fail, as
   for any unresolved LOOKUP); `SET a` and `SET A` stop conflicting; a mixed-case TRACK
   gets a new identity, so its counters start empty. A rule that relied on matching
   another case needs editing, and so does a `LOOKUP ... FROM` naming a table in
   uppercase.
3. A rule that relied on removing an object or another spelling needs editing, even
   if it is all lowercase: `UNSET card` or `SET user = 'redacted'` stops removing
   `card.number` or `user.name`, and `UNSET password` stops removing `Password`. Those
   columns are stored from the upgrade on, and a nested key that is not an identifier
   can no longer be removed at all. Review redaction rules before upgrading.
4. Rolling deploy: a mixed cluster stays available and behaviors differ only until
   every node is upgraded. SQL is parsed and resolved only on the node handling the
   query, and evaluation matches names exactly everywhere, so a query's acceptance
   and result depend on that node's version (a column or table in another case).
   A rule's effect depends on the version of the node ingesting the
   event: mixed-case names, and the removals in item 3. An UNSET of a list path written
   during the roll is a parse error on old nodes.
