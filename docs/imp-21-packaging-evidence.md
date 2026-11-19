# IMP-21 Packaging, Updates, Compatibility & Rollback Evidence

- **Issue**: `#21` (`[IMP-21] 패키징·업데이트·호환·롤백`)
- **OpenSpec**: [proposal.md](../openspec/changes/imp-21-packaging-compatibility/proposal.md) · [design.md](../openspec/changes/imp-21-packaging-compatibility/design.md) · [spec.md](../openspec/changes/imp-21-packaging-compatibility/specs/packaging-compatibility/spec.md)
- **Implementation**:
  - [PackagingAndMigrationManager.swift](../core/Sources/OchesCore/PackagingAndMigrationManager.swift)
  - [PackagingAndMigrationTests.swift](../core/Tests/OchesCoreTests/PackagingAndMigrationTests.swift)
  - [verify_packaging_and_hosts.mjs](../scripts/verify_packaging_and_hosts.mjs)
- **Verification Executed**:
  - `openspec validate imp-21-packaging-compatibility --strict` -> PASS (`Change 'imp-21-packaging-compatibility' is valid`)
  - `swift test --package-path core --filter "PackagingAndMigration"` -> 3/3 PASS (0.025s)
  - `node scripts/verify_packaging_and_hosts.mjs` -> PASS (`ok: true`, verified P1/P2/P7/P8/P9 manifest pins across Desktop, Core, Chrome Extension, Native Host template, and VS Code Extension)
- **Remaining Product Gates (`NOT RUN`)**:
  - Apple Developer ID code signing & Apple notarization ticket verification on release builds: **NOT RUN**
  - macOS Gatekeeper installation & live auto-updater channel rollout/rollback test: **NOT RUN**
  - Chrome Web Store & VS Code Marketplace store submission/review: **NOT RUN**
