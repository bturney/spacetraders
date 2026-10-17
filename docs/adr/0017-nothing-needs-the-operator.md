# Nothing needs the Operator: Plan Health replaces Attention

Status: Accepted

Date: 2026-10-17

The Mission Control information architecture made "does anything need me?" a core Operator question. Attention, pinned Activity attention, Intervention notifications, Manual Intervention, Ship Reservation and Emergency Stop all answered it. The Operator decided the Fleet plays autonomously and nothing needs them: a stuck Fleet is a tuning problem to analyse afterwards, never a prompt to act. The accepted Operator Experience Recovery prototype held that across all five tested situations. So Attention, Manual Intervention, Ship Reservation and Emergency Stop are retired. **Plan Health** (on plan, small setback, off plan, can't tell) is the only Operator-facing judgment, and it never asks for action. Stopping the service on `project-host` is the kill switch: Ships already in flight finish their legs either way.

## Considered Options

- **Keep Attention, quiet when healthy.** Rejected: any "needs you" surface invites manual gameplay, and keeping it would mean maintaining unused paths.
- **Keep Emergency Stop as the one escape hatch.** Rejected for a single-Operator hobby server, where stopping the service does the same job. Removing it also removes the stop-state checks on every mutation and the resume path.

## Consequences

The information architecture's "needs me" requirements no longer hold. Degraded Operation, Shortfall and Neutral Wait remain engine distinctions; Plan Health reads them but never surfaces them as calls to action. See [Decide the smallest cohesive Operator recovery contract](https://github.com/bturney/spacetraders/issues/744#issuecomment-6235115152).
