# Design

## Context

See the proposal. ADR-016 adopts a logical shared Core and versioned JSON/JCS while leaving implementation language, exact wire schemas and size limits to implementation. ARC-11 requires authenticated connection context and denies unsupported semantics. The design baseline is pending review in PR #24.

## Goals / Non-Goals

**Goals:** independently reviewable shell and contract changes, a strict parser before semantic validation, and reproducible evidence on macOS arm64.

**Non-Goals:** claiming that a stub provides XPC authentication, persistence, policy, or a production service.

## Decisions

- Separate the Flutter shell, logical Core, and transport interface. No transport is trusted merely because it implements the interface. XPC identity belongs to IMP-03; a placeholder reports unavailable. Alternatives such as direct UI-to-storage coupling would bypass the shared authority boundary.
- Choose the Core language and package structure in a dedicated ADR before implementation. Evaluate Swift's native XPC integration against Dart's shared toolchain and Rust's portable core and FFI costs. The choice is not yet made; do not present a candidate as an accepted contract.
- Reject malformed and ambiguous JSON while reading raw input, before ordinary decoding can discard duplicate keys or round numbers. Canonicalize only validated data with a pinned, independently tested RFC 8785 implementation. Library selection and concrete safe limits need an ADR or reviewable decision with evidence.
- Separate draft PRs for (1) baseline, (2) toolchain/shell and language ADR, and (3) wire schemas/parser and vectors. Each implementation PR must document its own I/O, errors, transitions, permissions and version boundary before code changes. Later PRs may be stacked while earlier work is in review, but dependent issues cannot be marked done before prerequisites are merged.

## Risks / Trade-offs

- [JCS library and numeric parsing diverge] → compare independent vectors and raw malformed inputs; reject uncertain cases.
- [Scaffold implies security support] → default protected paths to unavailable and label real OS tests NOT RUN.
- [Version or envelope proposal conflicts with later supplements] → review the latest ARC-10/11 and security supplements before fixing wire fields; record unresolved conflicts rather than inventing semantics.

## Migration Plan

No product data exists. Roll back each PR independently; preserve the baseline snapshot and explicitly note any later wire incompatibility. No production migration is implied.

Core language decision: [ADR-018](../../../docs/architecture/adr/ADR-018-core-language.md) proposes a separate Swift package with native adapters outside domain logic. Review and actual build evidence are still required.
