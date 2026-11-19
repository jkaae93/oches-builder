# Desktop Vertical Flow

## ADDED Requirements

### Requirement: Complete vertical workflow with Core authority
The Desktop client SHALL present the eight-stage vertical workflow (`scope → profile → recommendations → template → exportDiff → runApproval → monitor → evaluation`), remain fail-closed when Core is unavailable, and never mutate Core state during reconnect.

#### Scenario: Reconnect and cursor expiry (V-14)
- **WHEN** the Desktop client reconnects during an active attempt or receives `cursorExpired`
- **THEN** it performs only read-only inspect/poll or full snapshot resync without triggering automatic starts or mutations

### Requirement: Cancel request vs confirmed termination and monitor pacing (V-01 / P4)
The Execution Monitor SHALL distinguish `Cancel Requested` from confirmed `Cancelled` or `Evaluating` when normal exit wins a cancel race, and SHALL throttle monitor polling at most 4Hz (250ms minimum interval).

#### Scenario: Delayed cancel and normal exit race
- **WHEN** the user requests cancellation while a run is active and termination confirmation is delayed or normal exit completes first
- **THEN** the UI shows `Cancel Requested` until confirmation and updates to `Evaluating` if Core reports normal completion

### Requirement: Stale draft protection and honest cost/unknown rendering (P3 / P5)
Local template edits SHALL mark export plans stale and block config apply until revalidated and re-planned, and `UNKNOWN` or `SUBSCRIPTION_INCLUDED` cost records SHALL never display as `$0.00`.

#### Scenario: Local template edit after export diff and unknown cost
- **WHEN** a user modifies the template draft after generating an export diff or views an `UNKNOWN` / `SUBSCRIPTION_INCLUDED` cost entry
- **THEN** config apply is blocked as stale and cost output displays explicit status and source basis rather than `$0.00`
