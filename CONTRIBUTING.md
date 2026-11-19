# Contributing

## Branches

- `master` is the current default integration branch; do not commit directly to it. If the repository's default branch is renamed, update this rule.
- Branch from an up-to-date `master`, keep branches short-lived and focused, and delete them after merging.
- Use `feat/<name>`, `fix/<name>`, `docs/<name>`, `refactor/<name>`, `chore/<name>`, or `release/<version>`.
- Rebase or update from `master` before merging. Resolve conflicts in the feature branch.

## Commits

Use [Conventional Commits](https://www.conventionalcommits.org/):

```text
<type>(<optional-scope>): <imperative summary>
```

Common types: `feat`, `fix`, `docs`, `refactor`, `test`, `build`, `ci`, `chore`, and `perf`. Explain motivation and tradeoffs in the body when useful. Mark incompatible changes with a `BREAKING CHANGE:` footer. Keep commits focused; exclude unrelated formatting and generated files.

## OpenSpec

Use OpenSpec for changes to behavior, architecture, APIs, data, security, product requirements, or cross-module contracts. Typo fixes, isolated formatting, and routine dependency maintenance do not need a proposal.

1. For unclear scope, select the `openspec-explore` skill in Codex; then create a named change with `openspec-propose` and review its proposal, delta specs, design, and tasks before implementation.
2. Implement with `openspec-apply-change`, updating the artifacts when evidence changes the plan.
3. Verify against the requirements and applicable checks. Use `openspec-sync-specs`, then `openspec-archive-change` when complete.
4. Link the change in the PR. Keep current behavior in `openspec/specs/`, active deltas in `openspec/changes/`, and completed history in `openspec/changes/archive/`.

Install the CLI using the official guide and check `openspec --version`. The CLI is installed per developer machine; OpenSpec artifacts and generated project instructions belong in Git. Run `openspec update` after upgrading the CLI. For Codex, use the OpenSpec skills from the Skills sidebar or ask Codex to use the named skill; do not type slash commands unless the chosen assistant supports them.

OpenSpec records intent and behavior. Keep durable decision rationale in `docs/architecture/adr/`; link related ADRs and OpenSpec designs to each other. Do not replace existing architecture evidence or contracts without updating them deliberately.

## Pull requests

- Open PRs against `master`; use draft status while work is in progress.
- Keep each PR focused. Explain the problem, impact, and approach; complete the PR template and link relevant issues, OpenSpec changes, and ADRs.
- Update documentation and specs when behavior changes. Call out migrations, compatibility and security impacts, and follow-up work.
- Review the full diff for secrets, local files, unrelated edits, and accidental generated output before requesting review.
- Obtain one qualified approval when collaborators are available, resolve review conversations, and pass required CI checks before merging.
- Squash merge by default using a Conventional Commit title. Coordinate before force-pushing a branch already under review.

## Verification

Run relevant checks and record exact commands and results in the PR. For Dart/Flutter code, use the pinned toolchain and applicable formatter, analyzer, and tests (typically `dart format`, `flutter analyze`, and `flutter test`). Do not report checks that were not run. Add CI when buildable application code and its supported toolchain are established.

## Releases and security

- Use semantic versioning for distributable releases, document user-visible changes, and tag releases `vMAJOR.MINOR.PATCH`.
- Use a release branch only when stabilization requires one.
- Never commit credentials, signing keys, or environment-specific configuration. Document secret names and provide safe examples.
