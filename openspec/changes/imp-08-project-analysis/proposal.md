# Proposal

## Why

The project needs a trustworthy, bounded local project profile before recommendation or agent configuration can use project evidence.

## What Changes

- Add approved-scope preview and a descriptor-relative, no-symlink scanner with explicit exclusion and partial-failure reporting.
- Build versioned, evidence-backed profiles with local-only analysis, cancellation and stale detection.
- Apply ARC-02 and DESIGN_FINALIZATION N1–N7; test V-02 and failure/race cases.

Non-goals: executing project code, modifying project files, transmitting content, or claiming untested platforms supported.

## Capabilities

### New Capabilities

- `project-analysis`: Scoped local scanning and evidence-backed profile creation.

### Modified Capabilities

None.

## Impact

Swift Core, authorization, local storage and future desktop review. ARC-02, ARC-09, ARC-10 and DESIGN_FINALIZATION N1–N7 constrain behavior. Existing saved data migration is not anticipated until the storage schema is introduced.
