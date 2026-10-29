# fly-check-grace: Fly caps a health check's grace period at 1 minute

## Problem

The Fly configuration gave the `GET /health` check a 10-minute grace period, and the
docs said it allowed 10 minutes for a machine to load its segments. Fly caps a service
check's grace period at 1 minute: `fly config validate` warns "Service HTTP check has
a grace period greater than 1 minute (10m0s); this will be lowered to 1 minute"
(flyctl v0.4.111, `internal/appconfig/validation.go`). So the 10 minutes were never
applied, and the docs credited the check with something it doesn't do.

## Change

1. `grace_period` becomes `"1m"`, what Fly applies anyway.
2. The Fly guide and system.md say what actually covers a slow boot: `fly deploy`
   waits up to `--wait-timeout` (15 minutes in the guide) for each new machine's
   health check to pass (flyctl `internal/command/deploy/plan.go`,
   `WaitForHealthchecksToPass` with the deploy's wait timeout).

What Fly does with a running machine whose check keeps failing past the grace period
was not verified here; flyctl's source doesn't decide it.

## Product spec impact

None. Deployment documentation and the example configuration only; the applied
grace period is unchanged.

## Validation

`fly config validate --strict` on the configuration passes without the warning.
