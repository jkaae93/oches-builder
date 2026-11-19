# IMP-13 evaluation and independent observation progress

Date: 2026-11-19. Issue: #13. OpenSpec: `imp-13-evaluation-observability`.

## Implemented Core components

- **Immutable artifact snapshot & drift verification** (`core/Sources/OchesCore/ArtifactManifestStore.swift`):
  - Collects workspace artifacts safely below the canonicalized workspace root via `openat(..., O_NOFOLLOW | O_CLOEXEC)` and per-component `fstatat(..., AT_SYMLINK_NOFOLLOW)`.
  - Rejects path traversal (`..`, leading `/`, NUL), symlinks (`.symlinkRejected`), hard-link aliases (`st_nlink != 1`), and mid-read mutations (`fstat` before/after + `lstat` replacement check -> `.changedDuringRead`).
  - Stores content-addressed SHA-256 blobs with `0o444` read-only permissions and create-only `artifact_manifests` rows bound to `(workspaceID, runID, taskID, attemptID, taskRevision)`.
  - Verifies blob tampering (`verifyManifestIntegrity`) and live workspace drift (`compareManifestAgainstWorkspace`) without altering or reusing historical `PASS` verdicts on modified versions (V-11, X20).
- **Independent observation completeness & precedence** (`core/Sources/OchesCore/IndependentObservationVerifier.swift`):
  - Separates independent observer identity (`observerID != productSourceID`, `observerIsolated == true`) and checks `startMarkerRecorded`, `endMarkerRecorded`, strict `1...N` sequence continuity, zero dropped events, healthy collector, inactive sampling, and zero unobserved child processes across `ObservationBoundary`.
  - Enforces V-19 precedence: observed safety violations always yield `FAIL` (while preserving `unknownBoundaries` and `incompletenessReasons`), and missing/incomplete boundaries without violations yield `INDETERMINATE`. Rejects secret-like markers in violation details.
- **Evaluation engine, atomic scheduler binding & paired comparison accounting** (`core/Sources/OchesCore/EvaluationEngine.swift`):
  - Evaluates runtime attempt completion (`Succeeded` + identity match), manifest integrity, independent observation completeness, expected artifact digests, and oracle results, treating `requireHumanReview` (`AUTO_MATCH_HUMAN_PENDING`) as `INDETERMINATE` rather than `PASS`.
  - Records immutable `EvaluationVerdictRecord` rows in `EvaluationVerdictStore` and transitions `SchedulerRunRepository.applyEvaluation` atomically through `SQLiteStore.commitSchedulerEvaluation`.
  - Provides `aggregatePairedComparisons` for paired baseline/candidate 4-category accounting (`bothPass`, `baselineOnlyPass`, `candidateOnlyPass`, `bothFail`) while preserving `incompletePairs` and invalidating batches on duplicates or `datasetVersion`/`environmentDigest` mismatches.

## Verification

- `openspec validate imp-13-evaluation-observability --strict`: passed.
- `swift test --package-path oches-builder/core --filter EvaluationObservabilityTests`: 4/4 tests passed (covering V-11 cross-attempt `PASS` rejection, X20 workspace drift & blob tampering, V-19 violation vs completeness precedence, `AUTO_MATCH_HUMAN_PENDING`, and paired comparison batch aggregation).
- `swift test --package-path oches-builder/core`: full Core suite passed.

## Remaining product gates (issue #13 remains open)

- OS-level syscall/file/network independent observer daemon implementation and real 20-task human-approved dataset collection/scoring remain product gates outside this Core module boundary.
