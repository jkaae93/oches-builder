# Design

- **Environment & Workspace Trust Boundary (`src/environment_guard.mjs`, `package.json`)**:
  - Evaluates `env.remoteName`, `env.uiKind`, workspace URI scheme (`file:` only), and `workspace.isTrusted`.
  - Any remote host (`ssh-remote`, `wsl`, `dev-container`, `attached-container`, `tunnel`), Web UI, or non-`file:` workspace forces `UNSUPPORTED` status and rejects `analyzeWorkspace`, `applyPlan`, `startRun`, and `sendExternalContext` (`REMOTE_UNSUPPORTED`).
  - Restricted Mode (`!workspace.isTrusted`) permits read-only status/snapshot inspection only and rejects both UI triggers and direct Command Palette / API invocations (`RESTRICTED_MODE_DENIED`) with 0 Core calls. Trust and folder changes immediately re-evaluate and revoke stale capabilities.
- **Secret Storage (`src/secret_vault.mjs`)**:
  - Wraps `ExtensionContext.secrets` and inspects `safeStorage` backend availability.
  - Refuses `basic_text` or missing secret storage with `KEY_UNAVAILABLE`, guaranteeing zero fallback to `workspaceState` or `globalState`.
- **Webview & Noise Transport (`src/webview_bridge.mjs`, `src/extension_controller.mjs`)**:
  - Webview HTML embeds strict CSP with per-render cryptographic `nonce`, HTML-escapes all project/error strings as data, and strips any credential fields.
  - Inbound Webview messages enforce W1 256 KiB cap, webview ID verification, operation allowlist, unknown-field rejection (W7), and path-traversal/script rejection (`MALICIOUS_WEBVIEW_MESSAGE`).
  - Uses shared `NoiseIKInitiatorHandshake` / `NoiseTransportPeer` with JCS prologue, `publisher.name` identity tagged strictly as `USER_ENROLLED_KEY` (`sharedHostIsolationGuaranteed: false` across shared Extension Host processes), protocol version negotiation, `requestId`, `expectedRevision`, and `CURSOR_EXPIRED` -> read-only `getSnapshot` recovery with zero auto-starts.
