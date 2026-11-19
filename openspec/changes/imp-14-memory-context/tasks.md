# Tasks

- [x] Create OpenSpec specification for IMP-14 memory lifecycle, bounded context selection and deletion propagation.
- [x] Extend `BackupAndDeletionRecovery` deletion and backup-restore replay to propagate deletions across `memory_search_index` and `memory_evidence_links`.
- [x] Implement `MemoryStore` with 90-day TTL, YAML frontmatter rendering, Dreaming v1 rejection and safe derived index rebuild.
- [x] Implement `ContextBuilder` enforcing 64 KiB budget, partial timeout markers, pre-transfer revalidation and `EXTERNAL_TRANSFER` approval consumption.
- [x] Add regression tests for V-08, V-16, C-06, E7–E9 and record evidence (`docs/imp-14-memory-evidence.md`).
- [ ] Connect Desktop memory inspection/approval UI and end-to-end provider adapter injection (IMP-15/16).
