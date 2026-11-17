# Tasks

## 1. Decisions and review boundaries

- [ ] 1.1 Review latest ARC-10/11 and security supplements; record conflicts and unresolved schema details in an ADR or issue with sources.
- [ ] 1.2 Compare Core language/package options, record the chosen option and tradeoffs in an ADR, and verify it preserves the XPC and shared Core boundaries.
- [ ] 1.3 Open independently reviewable PRs with input/output schemas, errors, state transitions, permissions, version boundaries, migration and rollback recorded before implementation.

## 2. Desktop and Core scaffold

- [ ] 2.1 Pin the Flutter toolchain and scaffold macOS arm64 desktop and shared Core packages; verify a clean checkout builds using documented commands.
- [ ] 2.2 Introduce the transport interface and unavailable default; test protected operations fail closed without verified transport.
- [ ] 2.3 Add CI for format, analysis, tests and macOS build; verify an actual CI run and record its environment and result.

## 3. Wire contract

- [ ] 3.1 Define versioned request, response and event schemas, error taxonomy, requestId, revision and storeGeneration semantics; review them against latest architecture supplements.
- [ ] 3.2 Implement raw UTF-8 validation and strict JSON parsing with duplicate key, unsafe integer, null/omission, malformed Unicode and size-limit rejection tests.
- [ ] 3.3 Implement JCS plus SHA-256 with independent published vectors and cross-runtime comparison, documenting dependency and actual results.
- [ ] 3.4 Implement version negotiation and fail-closed dispatch boundary; test incompatible major/minor, unknown required semantics and unverified identity.

## 4. Integration and evidence

- [ ] 4.1 Run normal, refusal, failure and applicable concurrency regression tests on the product implementation; record commands, environment, expected and actual results and untested platforms in PRs.
- [ ] 4.2 Verify clean-checkout build and CI; sync accepted specs and document migration, rollback, remaining risks and review evidence.
- [ ] 4.3 Complete qualified review and merge; attach commits, PRs, test evidence and untested platforms to issue #1 before marking it Done.

## Workflow follow-up

- Archive the change after review and merge requirements are satisfied.
