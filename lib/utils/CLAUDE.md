# Utilities

Utilities are leaf helpers: build information (`Build`), segment IDs (`SegmentID`),
`SortedSet`, timestamps (`Timestamp`), and `Utils` (hostname, ETS streaming). They call
no other Guardian subsystem (Engine, Storage, Query, AST, Web, Cluster); keep it that
way, and put a helper with a single user next to that user instead.

- `SegmentID` creates sortable 32-byte hex identifiers containing a timestamp.
- `Timestamp.now/0` is UTC, formatted `YYYY-MM-DD HH:MM:SS`.

Utility changes should include focused unit tests.
