# IMP-09 validation progress

Date: 2026-11-18. Issue: #9.

Implemented the Swift neutral AgentDefinition validator using the existing raw JSON and canonical SHA-256 boundary. Enforces exact v1.0 fields, safe integer tokens, ASCII identifiers, nonblank bounded text, typed unique ports, unique tools, permission records and bounded resource limits. Definitions cannot include account, credential or execution-path fields. Validation performs no filesystem changes or provider operations.

Verification: `swift test --package-path core --filter AgentDefinitionValidatorTests` passed 4 tests covering valid canonical digests, duplicate keys/ports/tools, unknown fields, unsupported versions, invalid resource bounds, invalid port values and oversized documents. `openspec validate imp-09-agent-definition --strict` and `git diff --check` passed.

This is partial IMP-09 progress, not completion. Definition persistence, export mapping evidence, stale-plan rejection and verified approved filesystem application remain pending. IMP-10 through IMP-22 are still part of the active goal and have not been implemented by this change. IMP-08 approval/dispatch integration is also still pending. No PR merge, provider execution or account authentication changes were performed.

## Export planning progress

Added an internal export-plan builder that requires field-complete mappings and official plus experiment references for EXACT claims. Required tools, permissions, resource limits and input/output mappings reject any loss or unknown support. Plan digests bind definition content/revision/generation, Adapter and Provider versions, capability snapshot/version, target path/digest and mapping evidence. Revalidation rejects changed bindings using byte-exact string comparison. Optional non-safety loss is explicitly flagged for later approval integration. Evidence references are supplied by internal adapters, not a verified external support registry; the builder is not an authorization boundary and performs no writes.

`swift test --package-path core --filter AgentExportPlanTests`: two tests passed (complete mapping, stable canonical plan, changed Provider version, missing mappings/evidence and all non-exact permission mappings). Persistence and approved application are still pending; the combined OpenSpec task remains unchecked.

## Definition persistence progress

Added an internal create-only definition repository on SQLite's transactional state/event/idempotency storage. Each declared definition version has its own object; older versions remain readable. Same-request replays return the original result, different inputs conflict, and a new request cannot overwrite a published version. Loads verify owner, exact generation-bound storage revision and payload identity. No new database schema is introduced. This repository is not an authenticated endpoint; product authorization, deletion integration and export bindings that distinguish declared version from storage revision remain pending.

`swift test --package-path core --filter AgentDefinitionRepositoryTests`: two tests passed, covering restart, old-version retrieval, immutable publication, request replay/conflict and event-trigger failure rolling back publication. The combined persistence/planning task stays unchecked until the version-binding integration is complete.

## Stored definition/export version integration

Corrected the export builder's conflation of declared definition version and SQLite storage revision. Create-only published version 2 legitimately has storage revision 1. Plans now bind the exact ARC-04 object identity for the declared version and include the declared version separately in the canonical digest. A repository planning entry point loads and validates the persisted definition under the supplied generation-bound storage reference before creating the plan. Internal builder inputs alone do not prove persistence or authorization.

`swift test --package-path core --filter AgentExportPlanTests`: three tests passed, including publication and planning of version 2/storage revision 1, wrong definition identity rejection and stale-generation rejection. Approved content/diff binding, authenticated application, deletion integration and full V-04/C03 remain pending; IMP-09 is not complete.

## Export content and approval-request binding

Added a bounded UTF-8 export document containing exact before/after bytes. Its domain-separated approval digest binds the mapping plan and previous/proposed content hashes. Absence is distinct from an existing empty file. Revalidation rejects changed target contents or changed output. The document creates CONFIG_EXPORT_APPLY request bindings carrying the document digest, exact target version, definition storage reference and Adapter version; this does not issue approval or perform writes.

Regression coverage includes changed-output digests, changed target, absent versus empty target, malformed UTF-8, NUL, oversized content and invalid approval plan ID. Authenticated approval consumption and safe filesystem writes remain pending. No real Provider export mapping is claimed supported by synthetic mapping fixtures.

## Approval enforcer binding check

The existing config-apply branch previously checked approval shape but did not compare its plan binding with the requested operation. Added an expected apply binding to the internal authorized input and its idempotency digest. Inside the existing approval-consumption transaction, config apply now requires a byte-exact canonical match of plan ID/digest, target versions, definition revision and Adapter version, plus request-digest and canonical-target matches. Missing expected binding fails closed. This changes only internal apply requests; existing execution requests remain compatible.

Added canonical identity regression checks for target version changes, Unicode byte distinctions and incomplete bindings. Existing authorization regression tests pass. A dedicated end-to-end config-apply transaction test and safe filesystem application are still pending, so this is not evidence of completed V-04/C03 or product authentication.

## Apply authorization transaction evidence

Added `AgentApplyAuthorizationTests` using a temporary SQLite store, registered synthetic Desktop client, scoped approval and nonce. Missing or mismatched expected binding rejects the operation. Injected audit failure leaves the state absent and rolls back nonce and approval consumption; the same approval/nonce then succeeds with valid input. Reusing the consumed nonce is rejected. A fresh nonce with changed binding conflicts, while the same fresh nonce with the original binding retrieves the idempotent result without another state transition. The target file remains unchanged because this test verifies authorization/state recording, not filesystem application.

`swift test --package-path core --filter AgentApplyAuthorizationTests`: one transaction regression test passed. Synthetic registration and trusted-UI flags are test setup, not proof of authenticated product transport. Actual file writes and their crash/race outcomes remain pending.

## Descriptor-relative writer primitive

Added an internal config writer primitive with component-by-component no-follow directory traversal, exclusive creation, regular/single-link file checks, advisory locking, exact expected-content comparison, bounded writes and final content verification. It reports applied/conflict/unavailable/partial/unknown and does not claim multi-file atomicity. Existing-file writes modify the held descriptor in place; truncation/write failures can leave partial contents, as explicitly reported.

`swift test --package-path core --filter AgentConfigFileWriterTests` passed one test covering create, update, refusal to overwrite an unexpectedly existing file, changed-content rejection, subtree symlink denial and traversal rejection. This primitive is deliberately not wired to a product endpoint or approval path yet. Approved root descriptor identity, hostile concurrent replacement/in-place writes, failure injection, durable apply-intent/outcome recording and restart recovery remain pending. Advisory locking does not prevent uncooperative writers. These tests do not prove all race conditions safe or complete IMP-09.

## Writer fault and mutation checks

Added deterministic stage hooks and a second descriptor metadata check immediately before mutation. Tests replace the target inode or modify contents after initial comparison; both are rejected before the proposed content is written. Stage failures after exclusive creation or writes return Partial, and pre-sync/pre-verification interruptions return Unknown. `swift test --package-path core --filter AgentConfigFileWriterTests` now passes three tests.

These hooks simulate failures, not actual process crashes. There remains a race window after pre-write metadata checking, so uncooperative concurrent writers and renamed ancestor/root directories still require stronger coordination or explicit unsupported handling before product exposure. Durable apply intents, crash recovery and authenticated writer dispatch remain incomplete. The writer remains disconnected from production dispatch.

## Durable apply journal

Added an internal SQLite journal keyed by reviewed document digest, storing Applying intent and terminal per-file outcomes through existing atomic state/event/idempotency transitions. Recovery of an unfinished Applying intent records Unknown without invoking a writer. Terminal outcomes cannot be overwritten by an old intent reference; a new request cannot recreate the same document intent. A changed/newly approved plan must obtain a distinct document digest before reapplication.

`swift test --package-path core --filter AgentApplyJournalTests` passed a restart/reopen test covering intent replay, Unknown recovery, repeated recovery, late-success rejection and duplicate intent rejection. This test reopens SQLite; it does not kill the process. Journal, authorization and writer are still independent internal pieces. Atomic approval-to-intent integration, product dispatch, process-crash tests and root/race enforcement remain incomplete, so IMP-09 remains open.

## Atomic approval-to-intent integration

Added `recordAuthorizedIntent`, deriving the expected approval binding and Applying payload directly from the reviewed export document. It uses AuthorizationEnforcer's single transaction to consume the scoped approval and nonce while committing intent, idempotency result and mandatory audit. These intent rows are owned by ARC-09; the journal recognizes that owner for recovery and records subsequent ARC-04 outcomes. No writer is invoked by intent recording or recovery.

Extended the authorization transaction test with a document-bound approval: injected audit failure rolls back, the same nonce/approval then records intent successfully, and recovery marks it Unknown while the target remains absent. `swift test --package-path core` passed all 119 tests; `git diff --check` passed. Product transport, authenticated UI identity, descriptor-safe root binding and actual write coordination remain pending. The standalone non-authorized journal primitive remains internal and must not be exposed as a product command.

## Internal apply coordination

Added an internal coordinator that revalidates the current plan binding, rejects optional-loss plans until separately approved loss handling exists, atomically records the authorized intent, invokes an injected internal writer only for a newly committed intent, and stores the per-file outcome. Idempotent replay reads the current journal result without invoking the writer; an in-progress replay is reported Unknown without changing the live intent. Failure to durably record the writer's outcome returns Unknown, never Applied.

Extended the synthetic authorization test to invoke the descriptor-relative writer against a temporary target, verify exact output bytes and assert the writer runs once across a fresh-nonce replay. The transaction test still verifies audit-failure rollback before writing. This internal closure is a composition seam, not an authenticated caller-supplied callback or product API. Protected root identity, uncooperative-writer races, actual process-crash testing, outcome-commit failure injection and product transport remain required before exposure.

## Process-exit and outcome-commit failure evidence

Added subprocess tests that commit intent and call `_exit(71)` either immediately or after a successful temporary-file write. The parent verifies the exit code, reopens SQLite, recovers Unknown and checks the target remains absent or retains the one approved write, respectively. Recreating the same document intent is rejected. This proves these process-exit boundaries, not power-loss durability or every instruction boundary.

Added an event-trigger failure after a successful file write: the terminal outcome transaction rolls back to the original Applying revision; after removing the trigger, recovery records Unknown while preserving the file. Recovery never infers Applied merely from current bytes. `swift test --package-path core` passed 121 tests and `git diff --check` passed. Product authentication, root binding, hostile mutation enforcement, multi-file coordination and remaining IMP-09 acceptance coverage remain incomplete.

## Held write-root descriptor

Added an internal held-descriptor write root initialized against an expected device/inode identity. It rejects a replacement root at construction and duplicates the already-open descriptor for each write instead of reopening a pathname. The raw path writer remains an internal primitive for tests and compatibility; neither constructor proves authorization.

The root-replacement regression test moves the original directory and replaces its former path. A new bound root rejects the identity mismatch; the held root writes only to the original opened directory and leaves the replacement untouched. This deliberately proves descriptor identity rather than pathname freshness. Device/inode reuse across restarts, root/ancestor rename policy and cryptographically binding the held identity into reviewed approval remain pending. `swift test --package-path core --filter AgentConfigFileWriterTests` passed four tests. Product dispatch stays unavailable until these contracts are integrated.

## Approval-bound held-root identity

Export documents can now include the currently held root device/inode in their domain-separated approval digest. The internal apply coordinator rejects documents lacking a root identity. The held-root document writer checks that identity and derives its relative target from the plan's absolute path within the held root's recorded canonical path, then uses only the bound document's previous/proposed bytes. Existing path-based primitives remain internal and grant no approval.

Extended the synthetic apply transaction test to use the held-root document writer. A different root identity changes the approval digest and is rejected before target creation; the correct identity still supports one write and idempotent replay. Identity capture is not itself authentication, does not survive restart safely and does not yet define root/ancestor rename policy. Uncooperative writer races, optional-loss consent, multi-file application and authenticated product dispatch remain pending.

## Root session and pathname checks

Each held write root now receives an ephemeral UUID session ID. Reviewed documents bind that session into their approval digest; internal apply requires it, and the bound document writer rejects another root session even if device/inode match. A pre-write named-root check rejects a missing, renamed or replaced root path. The existing raw primitives remain internal and do not grant authority.

Regression checks verify a reopened root cannot use an older document, a new session changes the approval digest, and renaming the root causes the document writer to reject. This prevents these observed stale-root cases, not concurrent rename after checking or malicious in-place file mutation. Product transport and cross-module authorization, optional loss confirmation, multi-file approval/application and remaining filesystem race handling are still pending. No IMP issue was closed by this change.
