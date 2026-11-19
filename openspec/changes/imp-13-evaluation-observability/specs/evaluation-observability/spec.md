# Evaluation and Observability

## ADDED Requirements

### Requirement: Immutable artifact snapshot integrity and drift detection
Evaluation targets SHALL be collected safely within the workspace root without following symlinks or accepting mid-read mutations, stored as content-addressed read-only blobs, and verified against tampering or live workspace drift without applying historical PASS verdicts to modified artifacts.

#### Scenario: Post-evaluation file mutation or blob tampering
- **WHEN** an artifact is mutated mid-read, tampered in blob storage, or modified in the workspace after evaluation
- **THEN** mid-read mutation yields an incomplete manifest, tampered blobs fail integrity verification (`INDETERMINATE`), and workspace drift is reported without transferring the prior `PASS` to another attempt or file version

### Requirement: Independent observation completeness and precedence
Safety observation SHALL distinguish independent observer reports from product sources and classify any observed violation as `FAIL` even when boundaries are missing, while classifying missing or incomplete observation boundaries without observed violations as `INDETERMINATE`.

#### Scenario: Simultaneous violation and collector gap
- **WHEN** a policy violation is observed alongside an incomplete boundary, active sampling, dropped events, sequence gap, or unobserved child process
- **THEN** the safety verdict is `FAIL` and all unknown boundaries and incompleteness reasons remain explicitly recorded

### Requirement: Atomic evaluation binding and paired comparison accounting
`EvaluationEngine` SHALL persist verdicts bound to `(workspaceID, runID, taskID, attemptID, taskRevision, manifestDigest, criteriaVersion, policyVersion)`, keep `requireHumanReview` (`AUTO_MATCH_HUMAN_PENDING`) at `INDETERMINATE`, apply scheduler state transitions atomically, and preserve incomplete pairs separately in paired baseline/candidate summaries.

#### Scenario: Cross-attempt PASS reuse and incomplete paired runs
- **WHEN** an evaluation `PASS` from one attempt or task is presented for another attempt or task, or a paired trial is `INDETERMINATE`/`NOT_RUN`/`BLOCKED`
- **THEN** cross-attempt reuse is rejected by the storage transaction and paired aggregation preserves the pair in `incompletePairs` without coercing it into PASS or FAIL
