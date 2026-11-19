# IMP-19 Chrome MV3 Extension & Native Messaging Evidence

- **Issue**: `#19` (`[IMP-19] Chrome MV3·Native Messaging`)
- **OpenSpec**: [proposal.md](../openspec/changes/imp-19-chrome-extension/proposal.md) · [design.md](../openspec/changes/imp-19-chrome-extension/design.md) · [spec.md](../openspec/changes/imp-19-chrome-extension/specs/chrome-extension/spec.md)
- **Implementation**:
  - Core Host gate: [NativeMessagingHostGate.swift](../core/Sources/OchesCore/NativeMessagingHostGate.swift)
  - Chrome MV3 Extension: [manifest.json](../apps/chrome-extension/manifest.json), [host_bridge.mjs](../apps/chrome-extension/native-host/host_bridge.mjs), [key_vault.mjs](../apps/chrome-extension/src/key_vault.mjs), [content_script.mjs](../apps/chrome-extension/src/content_script.mjs), [worker_controller.mjs](../apps/chrome-extension/src/worker_controller.mjs), [sidepanel.mjs](../apps/chrome-extension/src/sidepanel.mjs)
- **Verification Executed**:
  - `openspec validate imp-19-chrome-extension --strict` -> PASS (`Change 'imp-19-chrome-extension' is valid`)
  - `swift test --package-path core --filter "NativeMessagingHostGate|NoiseIK"` -> 6/6 PASS (0.090s)
  - `node --test apps/chrome-extension/tests/chrome_extension.test.mjs` -> 4/4 PASS (70.3ms)
  - Verified controls: strict `allowed_origins` (`chrome-extension://<32 a-p>/`, zero wildcards), `argv[1]` origin verification & `USER_ENROLLED_KEY` (`directExecutionUnproven=true`), W1/P7 256 KiB native-endian 32-bit framing, real WebCrypto `extractable=false` Ed25519+X25519 keys with fail-closed `KEY_UNAVAILABLE`, Content Script spoofing stripped & tab/document navigation stale state, two-step capture vs Side Panel confirmation + Core `APPROVAL_REQUIRED`, `sendNativeMessage` block, and Noise IK reconnection via read-only `inspectState` cursor sync with 0 auto-starts (V-14, V-21).
- **Remaining Product Gates (`NOT RUN`)**:
  - Live Chrome 120+ browser runtime + macOS Native Messaging Host end-to-end execution: **NOT RUN**
  - Chrome Web Store review & minimum privacy policy compliance check: **NOT RUN**
  - OS-level proof against standalone direct Host execution by same-user malware: **UNPROVEN** (mitigated only by `USER_ENROLLED_KEY` + Desktop per-request approvals)
