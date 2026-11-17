# Tasks

## 1. Scope and scanner

- [ ] 1.1 Record and review exclusion patterns, path-specific exceptions and scope approval contract against N1/N4; verify no approval can be forged by caller input.
- [ ] 1.2 Implement descriptor-relative no-follow scanning and bounded reads; test normal trees, symlinks, path replacement, inaccessible files and oversized inputs.
- [ ] 1.3 Implement preview, exclusion and partial-reason reporting; test N2 limits and absence of outside reads or external transfers.

## 2. Profile and integration

- [ ] 2.1 Implement N3/N6 versioned profiles with evidence, unknowns, cancellation and stale detection; test changes and failures.
- [ ] 2.2 Integrate verified scope approval, authorization and durable storage with migration and rollback; test denial and transaction failures.
- [ ] 2.3 Verify malicious project text remains data and never reaches logs or network without separately approved transfer.

## 3. Evidence and review

- [ ] 3.1 Run V-02 and clean checkout/CI with environment, commands, expected and actual results and untested platforms recorded.
- [ ] 3.2 Review and merge independent PRs, sync specs, attach evidence and close issue only after all acceptance criteria pass.

## Workflow follow-up

- Archive the change after review and merge requirements are satisfied.
