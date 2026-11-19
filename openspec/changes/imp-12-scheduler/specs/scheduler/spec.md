# Scheduler

## ADDED Requirements

### Requirement: Bounded explicit scheduling
Scheduler SHALL require predecessor Task success, preserve FIFO for eligible tasks and reserve at most four active or uncertain workspace slots. Unverified account isolation and overlapping exclusive resource identities SHALL prevent concurrent dispatch.

#### Scenario: Unknown attempt
- **WHEN** an attempt outcome is unknown
- **THEN** its slot remains occupied and the scheduler does not automatically restart it

### Requirement: Approved durable attempts
Dispatch SHALL use a fixed Run/DAG revision and durable attempt reservation followed by separate approval before Runtime start.

#### Scenario: Changed plan
- **WHEN** the Run/DAG revision changes after approval
- **THEN** the old approval cannot start the changed task
