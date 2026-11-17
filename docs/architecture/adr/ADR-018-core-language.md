# ADR-018: Shared Core implementation language

Status: Proposed for implementation review, 2026-11-17. Refs #1. This does not claim XPC identity, key protection, or platform support has been verified.

## Context

ADR-016 separates the logical Core from transport and selects macOS XPC peer identity as a verification candidate. Phase 1 targets macOS arm64 and Flutter Desktop; later clients must use the same logical contract. Flutter's UI language does not prescribe the Core language. Actual signing, distribution and peer identity remain IMP-03 work.

## Decision

Implement the first shared local Core as a separate Swift package, with domain logic and wire validation independent of XPC and Flutter. Keep macOS service and transport adapters in separate targets. Flutter uses a transport interface; until a verified adapter exists it returns unavailable. Do not expose an unauthenticated local service as a substitute. This is a product implementation choice, not a change to ADR-016 or a claim that Swift alone enforces authentication.

## Alternatives

- Dart for both shell and Core reduces language count, but native XPC service lifecycle and identity would still require a native boundary and deployment integration.
- Rust could offer a portable Core, but introduces a toolchain and FFI boundary for the initial native macOS service. It is not installed in the observed development environment; that fact alone is not a portability assessment.
- Swift aligns the first service with the native macOS toolchain and supports a package boundary; later non-Apple hosts require an independently designed and tested transport and platform dependencies. Swift does not itself prove portability, security, or runtime correctness.

## Consequences and verification

Pin and document actual Swift/Xcode and Flutter versions in the build change. Test domain and wire code separately from native adapters. Verify a clean macOS arm64 build and CI; verify mutual XPC identity in IMP-03 with correctly signed binaries and negative controls before claiming support. Windows, Linux and remote hosts remain UNKNOWN. Reconsider the choice if platform validation or package dependencies prevent the required separation. No product data migration is introduced; revert the scaffold and ADR together if the decision is superseded before use.
