# Proposal

## Why

The project has an adopted architecture baseline but no product implementation or reproducible build. IMP-01 establishes a reviewable foundation before storage, identity, and authorization depend on it.

## What Changes

- Scaffold the macOS Flutter Desktop application and a shared logical Core with a separated transport boundary; record the Core language and package decision in an ADR.
- Specify and implement versioned command, query, and event envelopes, error classification, request identity, revision and store generation boundaries, and strict JSON/JCS handling.
- Pin the toolchain and establish clean-checkout build and CI, with independent JCS vectors and rejection tests.
- Split the work into independently reviewable PRs, with contract boundaries documented before implementation.

Non-goals: production XPC identity, SQLite durability, policy enforcement, provider execution, and declaring untested platforms supported. These belong to later issues. No design prototype test is product evidence.

## Capabilities

### New Capabilities

- `core-wire`: Version negotiation, envelope validation, canonicalization, and safe error behavior for the shared Core wire boundary.
- `desktop-foundation`: A reproducibly buildable macOS desktop shell with an explicitly separated Core transport boundary.

### Modified Capabilities

None.

## Impact

Introduces application and Core packages, versioned wire contracts, toolchain and CI configuration. ADR-016 D01, D02, D04, D05 and D08, ARC-11, ARC-10, and CONTRACT_FINALIZATION_PROPOSAL constrain the design. Authentication, authorization and persistence remain fail-closed and unimplemented until their own issues. No existing product data migration is expected.
