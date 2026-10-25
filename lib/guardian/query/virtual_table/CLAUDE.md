# Query Virtual Tables

The `schema` virtual table exposes tables and inferred column metadata from
every connected node, merged through `Guardian.Cluster.Metadata`.
SHOW TABLES and DESC resolve to SELECT statements against it.

Virtual snapshots must match normal segment snapshot behavior and cover every table.
Keep virtual-table keys explicit so SELECT * resolution is deterministic.
A virtual table is a column snapshot (`SegmentSnapshot.columns`), plain data built
per query, never a Segment process: nothing has to stop it when the query ends.
