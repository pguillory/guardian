# Failure diagnostics

Product spec impact: none. The existing independent, ordered event outcomes in
spec section 5 remain the contract; the reporting fix restores that behavior.
No statements change in overview.md or spec.md.

## Engine fun-frame reporting fix

Engine's ingestion failure reporter stripped arguments only from MFA four-tuples.
A valid BEAM fun stack frame raised inside the reporter, preventing the batch
from returning the failed event's outcome and continuing. Unsupported frames now
become a fixed redacted MFA frame. Existing normal frames keep their locations
and arities; no exception message or event data is added to logs.

The regression injects a fun frame holding a private marker through a test-only
String.Chars implementation. It checks the original failure kind, the redacted
frame, absence of the marker, the unchanged not-stored error and successful
storage of the next event only. The test reproduced the reporter's
FunctionClauseError before the fix.

Shared classification and stack-redaction ownership is a separate follow-up.
