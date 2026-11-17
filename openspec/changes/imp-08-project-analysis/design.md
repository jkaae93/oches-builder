# Design

## Context

ARC-02 and DESIGN_FINALIZATION N1–N7 govern the approved local analyzer. Existing path canonicalization alone is not a safe open boundary against replacement races. Scope authorization must derive from verified Core context rather than a caller-controlled boolean.

## Goals / Non-Goals

**Goals:** no root escape or symlink following; bounded work; explicit provenance and partial state; no raw project text in logs or external transfers.

**Non-Goals:** provider transfer, project code execution, editing workspace files, or treating untested platforms as supported.

## Decisions

- On macOS use a root directory descriptor and `openat`/`fstatat` with no-follow flags for every path component. Verify regular file type and identity through descriptors; never authorize based solely on a resolved path. This avoids check-then-open races; a path-only URL walk is rejected.
- Treat a scanner as an internal primitive and expose analysis only through verified authorization and a scope-bound approval. A fake approval flag does not satisfy N4. Record any integration limitation as unavailable rather than bypassing it.
- Use N2 limits: 10,000 files, 100 MiB total, 1 MiB per file, five minutes. Limit or access failure yields Partial; skipped oversized files retain metadata only. Default exclusions and path-specific exception handling need an explicit reviewable manifest before enabling content reads.
- Separate scope scanner from Profile persistence and consumer integration into reviewable PRs. Capture only provenance and bounded derived facts, never raw contents in logs or fixtures.

## Risks / Trade-offs

- [Filesystem replacement during scan] → descriptor-relative no-follow operations and mutation-race tests; detect change during reading.
- [Default exclusions are incomplete] → report exclusions and uncertainty, prohibit blanket override, require explicit path-specific review.
- [Approval and durable profile are not integrated] → fail closed and keep feature unavailable until verified end-to-end.

## Migration Plan

No existing profile records. Introduce versioned persisted schema only with a tested migration and rollback in the profile PR.
