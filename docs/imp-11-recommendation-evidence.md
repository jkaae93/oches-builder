# IMP-11 recommendation progress

Date: 2026-11-18. Issue: #11. OpenSpec: `imp-11-recommendation`.

Implemented a bounded deterministic evaluator for versioned declarative constraints with equals/notEquals/atMost/atLeast predicates over boolean, integer and byte-exact text facts. Missing facts and incompatible types return Unknown. Duplicate constraint IDs and invalid logical identifiers reject. Each assessment retains constraint ID/version, so contradictions cannot be averaged away or silently removed. Six frozen pattern kinds are represented; this does not yet generate their configurations.

`swift test --package-path core --filter RecommendationConstraintTests` passed a test demonstrating a read-only/required-write contradiction, missing required resume fact, string-versus-integer mismatch and duplicate-ID rejection. `openspec validate imp-11-recommendation --strict` passed.

Still required: six pattern generation with mandatory Single Agent baseline, actual Profile/Registry/capability integration, explanations and uncertainty, version-bound proposal persistence/staleness, user acceptance and the fixed 20-case repeated evaluation. This primitive grants no runtime or provider support and does not close IMP-09/10 dependency gates. IMP-12 through IMP-22 remain in the active goal.

## Six pattern skeletons and Single Agent baseline

Added deterministic generation of six frozen pattern descriptors with Single Agent first. Each carries bounded task/dependency skeletons, structural facts, per-constraint assessments, static rule-version evidence, explanatory claim, simpler Single Agent alternative and explicit cost/latency/quality/capability/policy uncertainties. Parallel workers precede aggregation; orchestrator/workers have explicit coordination dependencies. All skeleton DAGs are validated.

Routing and evaluator-optimizer descriptors are explicitly blocked as requiring unsupported v1 conditional/loop semantics; their illustrative skeletons are not executable substitutes. Every candidate remains marked non-executable. Static rule evidence describes topology only, not project suitability, Provider support or superior quality. `swift test --package-path core --filter ArchitectureCandidateGeneratorTests` passed a regression test covering all six candidates, baseline inclusion, constraint outcomes, DAG validity and explicit unsupported/unknown markers.

Profile-derived evidence/version pins, actual Registry definitions, capability/policy checks, accepted proposal persistence and fixed evaluation are still pending. The generation/explanation task remains unchecked until those explanation inputs are integrated.

## Proposal input identity and freshness

Added input pins covering full Profile content hash and generation/revision, workspace-bound capability scope, snapshot ID/time and sorted entry status/basis/evidence, Registry revision references, typed constraint content/version and generator rule version. Capability policy version is included through scope. Internal proposal freshness rejects any changed digest, times before creation and the frozen 24-hour expiry boundary. Account references are hashed as part of private scope identity, never emitted as explanation text.

`swift test --package-path core --filter RecommendationVersionPinsTests` passed a test using an actual analyzer Profile draft and capability snapshot, checking unchanged pins, changed Profile revision, same-ID snapshot time change, expiry and backward time. Capture checks input binding but does not authenticate a caller or establish that passed records were loaded under current authorization. Persisted Profile/Registry lookup, actual capability eligibility, evidence-backed recommendations and acceptance remain pending.

## Persisted Profile and capability assessment integration

Added an internal recommendation service that loads the exact saved Profile revision, captures input pins, generates the six candidates and invokes the existing CapabilityEvaluator under the requested scope. Candidate assessments preserve failed/unknown constraints, unsupported patterns, capability scope/support status and incomplete Profile state. Required capability IDs now participate in proposal identity. Evidence refers to the Profile revision; private project contents are not copied into generated explanations.

Extended tests save the actual Profile in SQLite and verify missing required resume support and documented-only supported resume both remain Unknown, with Single Agent retained and execution explicitly unauthorized. This is not authenticated product routing, verified provider support or Registry lookup. Registry references remain pinned but unresolved, and policy/approval are not evaluated by this service. Technical requirement pass is not execution permission. Accepted proposal persistence, consumer integration and fixed evaluation remain pending.

## Proposal and selection persistence

Added an internal create-only proposal repository preserving input digest, Profile evidence references, creation time, candidate tasks/dependencies, claims, rule evidence/version, alternatives, uncertainties and requirement assessment/reasons. A separate acceptance record binds proposal generation/revision, selected pattern and input digest and explicitly records `executionAuthorized: false`. Acceptance requires matching current pins, age below 24 hours and a stored technical requirement pass; unknown/failed choices reject. Selection grants no runtime permission.

Storage tests use synthetic assessments (not actual provider support) to verify save replay, unknown-choice rejection, stale-input rejection, acceptance replay, explicit nonauthorization and expiry. Product UI authentication, current domain lookups, policy checks, selection change/revocation semantics and consumer integration remain pending. The adapter is not exposed as an authenticated endpoint. Fixed 20-case evaluation is still not run.
