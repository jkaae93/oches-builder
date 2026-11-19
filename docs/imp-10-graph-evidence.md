# IMP-10 graph validation progress

Date: 2026-11-18. Refs #10. OpenSpec: `imp-10-template-registry`.

Implemented the internal bounded Task dependency validator for TEMPLATE_GRAPH_SPEC_V1: unique ASCII task IDs, at most 1024 tasks and 4096 combined dependency/data-flow relations, existing distinct endpoints, no duplicate dependency edges, iterative topological sorting and explicit transitive dependency paths for every producer/consumer data flow. Data edges never create implicit ordering. This primitive accepts already-decoded task references; it is not the full exchange parser, template registry or authorization boundary.

`swift test --package-path core --filter TaskDependencyValidatorTests`: two tests passed covering transitive order, independent tasks, missing data order, cycles, duplicate dependencies/IDs, absent references and size bounds. `openspec validate imp-10-template-registry --strict` passed.

Still required: strict full exchange schema, six node/seven relation semantics, port typing and JSON unknowns, immutable version persistence, independent instances, import/publication/migration approvals, version-bound validation reports and TG-01 through TG-10 product acceptance. IMP-09 remains incomplete, and this work does not remove its dependency gate or make IMP-10 executable. IMP-11 through IMP-22 remain within the active goal.

## Port-level data semantics

Added a separate internal typed-port validator with bounded nodes/ports/edges, ASCII identity checks, unique direction-specific ports, existing source-output and target-input references, matching non-control data types, single source per input, explicit external-input declarations and required data-input coverage. JSON-to-JSON edges remain compatibility Unknown because no validated sub-schema contract is available. Control edges are rejected by the data validator and remain the dependency/relation layer's responsibility.

`swift test --package-path core --filter GraphPortValidatorTests` passed a regression test covering valid text flow, JSON unknown, duplicate sources, external/graph source conflict, missing required input, explicit external input, control-as-data rejection and reversed direction. These structural checks neither authorize actual external inputs nor verify source data, permissions or capability support. Full exchange parsing, relation ownership, Registry and cross-validator integration remain pending; the combined OpenSpec task remains unchecked.

## Typed relation structure

Added an internal typed relation validator representing six node kinds and seven relation kinds. It checks endpoint existence, duplicate relations, Task-to-Agent role assignment (ambiguous multiple assignments rejected), Agent/Task-to-Tool/Memory references, Task-to-Evaluation/Approval references, and Task control-port dependency edges. Data edges invoke port validation and Task-to-Task data flow invokes explicit dependency-path validation. This layer does not inspect node payloads, revision-pinned domain references, capability support or authorization; proposed-action approval ownership beyond Task is not yet represented.

`swift test --package-path core --filter TemplateRelationValidatorTests` passed a regression test covering all five reference relation kinds, invalid direction, missing reference, duplicates and ambiguous role assignment. Dependency/data integrated tests, full node payload validation and exchange parser remain pending, so the combined OpenSpec task is not complete. Existing primitive dependency/port tests continue to cover their respective boundaries independently.

## Version-bound validation reports

Added internal report bindings for instance generation/revision, exact definition references, graph content digest, schema version, capability snapshot/version, policy version and validator version. Canonical domain-separated hashing preserves byte identity and sorts definition references. Duplicate definition IDs, invalid revisions and unsupported schema bindings are rejected. Report freshness rejects any binding change, times before observation and age at or beyond the frozen 24-hour limit.

Structural, capability and policy results independently retain pass/fail/unknown. Freshness validation does not authorize execution or convert unknown support into success. `swift test --package-path core --filter TemplateValidationReportTests` passed a regression test covering instance/policy/snapshot changes, TTL boundary, backward time and malformed revision. Binding generation from full parsed/authorized node data, persistent report provenance and consumer integration remain pending.

## Bounded exchange envelope candidate

Added a JSON-only exchange-envelope candidate parser using the raw duplicate-key and safe-number boundary: 1 MiB document, 32 levels, 64 KiB strings, exact v1.0 version tokens, known root/metadata/requirements keys, bounded metadata lists, nonempty node list (1024 max) and 4096 edges. It retains canonical content/digest and raw node/edge values. Unknown root fields, duplicate keys, unsupported versions and malformed envelope shapes reject without executing anything.

`swift test --package-path core --filter TemplateExchangeCandidateTests` passed two tests covering canonical identity, unknown fields, duplicate keys, version/type mismatch, empty graphs and byte limits. This is explicitly an unvalidated candidate: node payloads, edge fields, capability/permission records and external-input entries still require the full exchange schema and typed semantics integration. YAML import, local Draft 2020-12 schema publication, Registry publication and execution remain unavailable. Empty node payloads may be staged as candidates but cannot be considered validated templates.

## Durable import-candidate staging

Added an internal SQLite candidate repository preserving canonical content and untrusted provenance in a create-only candidate object. State/event/idempotency recording is atomic through existing storage. Provenance participates in request identity; hash equality never grants shared origin or authority. Loads require exact object/generation/revision and ARC-15 ownership, reparse the envelope and enforce the 24-hour lifetime including backward-time rejection. Expiry denies access; physical retention/deletion enforcement is still pending. Canonical envelope output is also bounded to 1 MiB.

`swift test --package-path core --filter TemplateCandidateRepositoryTests` passed a regression test covering reopen, exact content/provenance, request replay, provenance conflict, TTL boundary, backward time and wrong candidate identity. Candidate IDs are supplied only to this internal adapter; product command allocation/authentication remains pending. Staging is neither publication nor full graph validation and invokes no provider or graph execution. Immutable published versions, instances, reviewed import confirmation and deletion integration remain incomplete.

## Integrated structural validation and report identity

Added relation-level integration tests proving valid transitive Task data order, missing-order rejection, cycle rejection, invalid dependency port types, non-Task control dependency rejection, data type mismatch and JSON unknown. Added a structural graph digest covering typed nodes/ports, required flags, relation endpoints and external declarations; the report factory runs actual relation/port/dependency checks and rejects a mismatched structural digest before reporting structural pass. Capability and policy remain Unknown.

The structural digest is not the full exchange-content digest: node-specific payloads, references and requirements are still outside this typed projection and require the pending full schema/consumer integration. The factory is internal and does not make a template executable. Report tests verify matching structure and mismatched digest behavior. Registry publication, independent instances and the remaining full-goal work stay incomplete.

## Expired candidate redaction

Added an internal expiry operation that verifies exact candidate revision, ownership and elapsed 24-hour TTL, then atomically replaces current content/provenance with an expired marker and emits a content-free event. Reads reject expired markers. Retained original request results prevent replay from restoring content or extending its lifetime; a new request cannot overwrite the same candidate identity.

Extended repository tests cover early-expiry denial, boundary expiry, current-state redaction, expired reads, original-request replay without state change and new-request overwrite denial. This is logical redaction from current application state, not secure erasure of SQLite pages/WAL/backups, and no automatic cleanup scheduler is present yet. Full deletion/recovery policy remains a separate unfinished product gate.

## Immutable snapshot and instance storage primitive

Added internal create-only family/version snapshots and independently copied instance payloads on existing SQLite state/event/idempotency storage. Instance edits use expected revision and retain source provenance without reading live source content; immutable snapshots cannot be overwritten through this adapter. Serialized payload ordering is fixed for deterministic request identity. No schema migration is introduced.

`swift test --package-path core --filter TemplateSnapshotRepositoryTests` passed a regression test creating one source version and two instances, editing one instance, verifying the source/other instance hashes stay unchanged, rejecting version overwrite and rejecting stale edits. These are storage snapshots, not Published lifecycle records: envelope-only input validation still permits unvalidated node payloads, so no publication or execution is authorized. Family revisions/built-in restrictions, full validation, import/publication approval, archive/deletion handling and product endpoint integration remain pending; the combined immutable-version/instance task stays unchecked.

## Instance retry and storage-failure correction

Removed an instance adapter precheck that rejected a successful edit's retry before SQLite could recognize the same idempotent request. Current ownership/provenance is still checked; the transaction owns expected-revision and request-identity decisions. A new request with stale revision still conflicts, while the original request returns its recorded result and changed input under that request conflicts.

Extended snapshot tests also inject an event insertion failure and verify no instance change or request result is committed, then successfully retry the same request after removing the failure. Removing a source snapshot directly in the fixture does not remove or change an independently copied instance. This is a storage independence test, not a product archive/deletion authorization test. Full schema, validated publication, family lifecycle and product integration remain pending.

## Exchange-to-structure decoder integration

Added an internal decoder linking the documented Agent-node exchange example to strict AgentDefinition validation and typed graph checks. Agent-node keys, labels, capability requirement record shape, local external-input declarations and relation field/direction semantics are checked. Unknown node kinds currently reject explicitly instead of being silently omitted. Root external declarations are passed through the port validator. No execution or publication is introduced.

A decoder regression test covers a valid Agent exchange, unknown node fields, non-Agent rejection and invalid embedded definition limits. This is an incomplete full decoder: Task/Tool/Memory/Evaluation/Approval payload schemas and reference semantics, root requirement record validation, local JSON Schema publication and YAML handling remain pending. Agent structural success alone cannot authorize capabilities, policy, Registry publication or execution; the full-schema OpenSpec task remains unchecked.

## Task payload decoding

Extended the exchange decoder with strict Task payload fields recorded in the OpenSpec design: goal, typed inputs/outputs and resource limits with 1–86400 seconds and 0–3 retries. Port lists are bounded before mapping. Task payloads now participate in the existing typed dependency/data validation rather than being discarded. Invalid limits, blank goal and unexpected account-reference fields reject.

`swift test --package-path core --filter TemplateGraphDecoderTests` passed two tests for Agent and Task payloads. These checks validate declarations only; Runtime enforcement, required Agent/evaluation bindings, full node-specific reference resolution, the remaining four node payloads, root requirements, complete schema and reviewed publication are still pending.

## Remaining four node declaration payloads

Extended the decoder to Tool, Memory, Evaluation and Approval payloads with strict per-kind keys documented in the OpenSpec design. Logical domain references require ID and positive decimal revision. Tool permissions require action/scope/approvalRequired; Memory requires evidence references; Evaluation pins criteria/evaluator references; Approval describes a requirement with target revision and a bounded duration, never an actual approval record. Embedded credentials and other undeclared fields reject.

Added tests for each declaration kind and unknown-field denial. This completes representation of six node kinds in the decoder, not full semantic support: referenced records, permission validity, enforcement, runtime evaluation targets, root requirements, formal local schema, YAML and reviewed publication remain pending. Original candidate content remains the source for payload persistence because the typed structural projection does not yet carry every domain field.

## Root requirements and domain reference retention

The decoder now validates root capability records (capability/required) and permission records (action/scope/approvalRequired) rather than accepting arbitrary array items. It retains domain references with originating node, reference role, logical ID and revision, plus the complete canonical exchange digest. This enables subsequent owner-domain checks without silently dropping Memory/evidence, criteria/evaluator or approval-target references.

Extended decoder tests verify Memory/evidence reference retention, full exchange identity and malformed root requirement rejection. These are syntactic checks, not a resolver or permission engine. The references still require lookup under authenticated workspace context, exact revision/existence checks, evidence validity and access authorization before publication or execution. Requirement identifiers also remain logical declarations until ARC-05 resolves them. Formal local schema, YAML, family lifecycle and reviewed Registry operations remain incomplete.

## Local structural JSON Schema

Added `core/contracts/template-exchange-v1.schema.json` declaring Draft 2020-12 with local fragment references only, all six node payload shapes, seven relation shapes, typed ports and root metadata/requirements. Embedded AgentDefinition uses the existing logical v1 shape. This schema describes structural values only; UTF-8 byte bounds, exact numeric token checks, duplicate JSON keys, UInt64 reference upper bounds, DAG/type/reference authorization and approval are enforced separately by Core.

The default Python lacked jsonschema, so verification uses `/tmp/oches-schema-verification`, created with the repository's existing pinned `core/contracts/tests/requirements.txt`. `/tmp/oches-schema-verification/bin/python -m unittest discover -s core/contracts/tests -v` passes nine tests, including local schema validity, six node shapes/unknown fields and no remote references. Existing CI discovers the new tests automatically. Shared cross-language fixture parity, full semantic resolution, YAML and Registry publication remain pending; schema presence alone does not complete IMP-10.

## Shared schema/Core fixture parity

Added a shared 13-case JSON corpus consumed by Python Draft 2020-12 validation and Swift decoding. Each case separately declares structural-schema validity and Core semantic validity, so duplicate nodes and unbound required inputs can be structurally valid but rejected semantically. Cases cover six valid node kinds, unknown fields/major, retry limits, duplicate nodes, missing inputs, malformed requirement types and newline identifiers.

The corpus exposed JSON Schema's end-anchor acceptance of a trailing newline in IDs while Swift rejects it. Added explicit newline rejection to logical IDs and domain revision patterns, including embedded AgentDefinition IDs. Python's complete contract suite now passes 10 tests. Swift shared fixtures are part of the full Core suite. This corpus is bounded evidence, not proof that every schema/decoder input agrees; full domain authorization, YAML, Registry lifecycle and product integration remain pending.

## Full exchange identity in validation reports

Added a full exchange digest alongside the structural digest in report binding identity. The candidate-report factory reparses canonical content, requires the complete exchange digest, decodes and validates all represented node/edge payloads and checks the structural projection digest before producing a report. Older structural-only reports remain internal helpers and cannot pass the candidate-report factory without full identity.

Regression tests modify Agent instructions without changing graph topology/ports. The structural digest remains equal, but the old candidate binding is rejected and the old report becomes stale under the new full exchange digest. Missing full exchange identity also rejects. Capability/policy remain Unknown; this strengthens content binding without resolving domain references or granting publication/execution. `swift test --package-path core --filter TemplateValidationReportTests` passes three tests.
