# IMP-14 memory, context selection and deletion propagation progress

Date: 2026-11-19. Issue: #14. OpenSpec: `imp-14-memory-context`.

## Implemented Core components

- **Evidence-backed Memory store** (`core/Sources/OchesCore/MemoryStore.swift`):
  - Persists canonical `MemoryEntryRecord` entries under `arc08/memory/<memoryID>` in `operational_state` (`owner_module = 'ARC-08'`) and derived metadata in `memory_search_index` / `memory_evidence_links`.
  - Requires non-empty `evidenceRefs`, rejects secret-like content, enforces live evidence and deletion checks before promoting `Candidate → Verified` with frozen 90-day `expiresAt` (`7,776,000` seconds, E7), renders Markdown + YAML frontmatter, rejects Dreaming in v1 (`dreamingUnsupportedV1`, E9), and rebuilds derived indices (`rebuildDerivedIndex`) strictly from non-deleted canonical records with non-deleted evidence.
- **Bounded Context Builder & pre-transfer revalidation** (`core/Sources/OchesCore/ContextBuilder.swift`):
  - Enforces the frozen 64 KiB (`65,536` bytes, E8) context budget, reloads canonical entries rather than trusting derived index status, records explicit `excludedItems` reasons (`notVerified`, `staleExpired`, `evidenceDeleted`, `evidenceChanged`, `permissionRevoked`, `policyChanged`, `budgetExceeded`, `timeoutPartial`, `deleted`), marks `partial: true` on 5-second timeout, and persists non-transferring `ContextSelectionRecord` (`transferExecuted: false`) with a canonical `transferPreviewDigest`.
  - `revalidateAndAuthorizeTransfer` verifies exact `storeGeneration` + `selectionRevision`, `policyVersion`, caller scopes, memory expiry/state, and live evidence revisions/digests/deletions immediately before transfer, then atomically validates and consumes a single-use `EXTERNAL_TRANSFER` approval bound to `contextSelectionRevision` and `transferPreviewDigest` (V-08, C-06).
- **Deletion propagation across index & backup restore** (`core/Sources/OchesCore/BackupAndDeletionRecovery.swift`):
  - Extends `DeletionRequestLifecycle.executeDeletion` and `BackupAndRecoveryManager.restoreWorkspaceFromBackup` replay to delete affected `memory_search_index` and `memory_evidence_links` rows whenever a memory or its underlying evidence is deleted (V-16).

## Verification

- `openspec validate imp-14-memory-context --strict`: passed.
- `swift test --package-path oches-builder/core --filter "MemoryAndContextTests|FreshnessAnchorRecoveryTests"`: 6/6 tests passed (covering 90-day TTL, YAML frontmatter, Dreaming rejection, 64 KiB budget, timeout partial markers, V-08 post-selection revocation/mutation blocking, and V-16 deletion propagation across index rebuild and pre-deletion backup restoration with `storeGeneration` rotation).
- `swift test --package-path oches-builder/core`: full Core suite passed.

## Remaining product gates (issue #14 remains open)

- Desktop UI inspection/approval flows and real Claude/Codex Provider context-transfer execution wiring remain for IMP-15/16/17.
