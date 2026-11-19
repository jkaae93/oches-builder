# Tasks

- [x] Create OpenSpec specification for IMP-13 immutable artifacts, independent observation and evaluation.
- [x] Implement `ArtifactManifestStore` with safe root traversal, read-only blobs, integrity verification and workspace drift checks.
- [x] Implement `IndependentObservationVerifier` enforcing V-19 violation vs completeness precedence.
- [x] Implement `EvaluationEngine` integrating runtime/manifest/observation checks, atomic scheduler binding and paired comparison aggregation.
- [x] Add regression tests for V-11, V-19, X20 and paired comparisons, and record evidence (`docs/imp-13-evaluation-evidence.md`).
- [ ] Connect OS-level syscall/network independent observer and 20-task human-approved real evaluation suite (product gate).
