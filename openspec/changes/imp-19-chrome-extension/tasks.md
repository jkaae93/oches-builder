# Tasks

- [x] Create `openspec/changes/imp-19-chrome-extension/` specification and design docs.
- [x] Implement `core/Sources/OchesCore/NativeMessagingHostGate.swift` and `NativeMessagingHostGateTests.swift`.
- [x] Implement `apps/chrome-extension/` MV3 manifest, Native Host template/bridge, WebCrypto + IndexedDB key vault, Content Script, Service Worker controller, and Side Panel UI.
- [x] Implement `apps/chrome-extension/tests/chrome_extension.test.mjs` covering V-14, V-21, W1/P7 256 KiB framing, origin spoofing, stale tabs, Worker restart recovery, and Noise IK exchange.
- [x] Run `openspec validate imp-19-chrome-extension --strict`, `swift test`, and `node --test`, then record evidence in `docs/imp-19-chrome-evidence.md` and GitHub issue `#19`.
