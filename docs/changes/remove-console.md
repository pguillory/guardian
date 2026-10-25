# Remove the custom Console helper

Status: complete.

The custom SQL table printer and VM-stop helper had no production callers. Remove
the module, its unit tests, the printer-only MCP assertions and the dead IEx import
scaffolding. The ordinary release remote IEx shell remains available with full VM
access, including direct queries and the operator's Storage escape hatches.

Product spec impact: sections 2 and 4.4 describe direct `Query.execute/1` calls and
their tuple results instead of promising a box-drawn table printer. Direct IEx
queries remain unlogged. Overview impact: none.

Validation: reviewed separately from the subsequent module namespace change; both
changes are covered by the final pre-commit checks recorded with that change.
