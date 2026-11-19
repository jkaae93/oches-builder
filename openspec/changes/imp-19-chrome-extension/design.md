# Design

- **Platform Boundary (`NativeMessagingHostGate.swift` & `native-host/host_bridge.mjs`)**:
  - Host manifest enforces `type: "stdio"`, exact 32-char lowercase `[a-p]` `chrome-extension://<id>/` entries in `allowed_origins`, zero wildcards, and rejects unknown keys (W7).
  - Host verifies Chrome's `argv[1]` caller origin against exact `allowed_origins` and refuses payload-level origin overrides.
  - Because standalone local execution of the Host binary can spoof `argv[1]`, Chrome Native Messaging attribution always remains `USER_ENROLLED_KEY` (`directExecutionUnproven = true`) and relies on `Noise_IK_25519_ChaChaPoly_SHA256` plus Desktop trusted-UI per-request approvals.
  - Native-endian 32-bit length prefix rejects empty or `> 262_144` byte frames (W1/P7) before buffering or JSON parsing.
- **Extension Key Vault (`src/key_vault.mjs`)**:
  - Uses `crypto.subtle` with `extractable: false` for installation `Ed25519` signing keys and `X25519` keys alongside IndexedDB storage, failing closed with `KEY_UNAVAILABLE` whenever IndexedDB or WebCrypto is unavailable or missing keys (no `chrome.storage.sync` or plaintext fallback).
- **Content Script & Service Worker Boundary (`src/content_script.mjs`, `src/worker_controller.mjs`)**:
  - Content Script has zero Native Host / Core / approval API access and strips spoofable payload fields.
  - Service Worker trusts only browser-supplied `sender.origin` / `sender.url`, `sender.tab.id`, `sender.frameId`, and `sender.documentId`, marks selections `stale` on tab navigation/URL change/document replacement/tab removal/permission revocation, and separates local selection from explicit Side Panel confirmation + Core `APPROVAL_REQUIRED` execution.
  - Uses persistent `connectNative` ports only (rejecting `sendNativeMessage` for stateful/streaming flows); on disconnect or Worker restart, clears auth state, re-authenticates via Noise IK, and performs read-only `inspectState` / cursor polling without auto-starting runs.
