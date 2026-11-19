# VS Code Local Extension Boundary

## ADDED Requirements

### Requirement: Local Workspace Trust and Remote Host v1 blocking (P2 / P8 / V-14)
The VS Code extension SHALL require VS Code `>= 1.85.0`, enforce local `file:` filesystem workspaces only in v1, block SSH/WSL/Dev Container/Web hosts with `UNSUPPORTED` status and disabled dangerous actions, block direct invocation of analyze/apply/run/transfer commands in Restricted Mode (`RESTRICTED_MODE_DENIED`) with zero Core calls, and immediately re-evaluate authorization upon trust or workspace folder changes.

#### Scenario: Restricted Mode direct invocation and Remote Host blocking
- **WHEN** `workspace.isTrusted` is false, trust is revoked mid-session, or `env.remoteName` indicates `ssh-remote`/`wsl`/`dev-container`
- **THEN** direct command calls throw `RESTRICTED_MODE_DENIED` or `REMOTE_UNSUPPORTED` with 0 Core requests sent

### Requirement: SecretStorage safeStorage enforcement, Webview sandbox, and Noise IK cursor recovery
The VS Code extension SHALL store enrolled client keys in `ExtensionContext.secrets`, fail closed with `KEY_UNAVAILABLE` if `safeStorage` degrades to `basic_text` with zero `globalState`/`workspaceState` fallback, enforce CSP/nonce/schema/size limits on Webview messages without leaking credentials, classify `publisher.name` under `USER_ENROLLED_KEY`, and recover from `CURSOR_EXPIRED` via read-only snapshot sync with zero auto-starts.

#### Scenario: Weak secret backend, malicious Webview payload, and cursor expiration
- **WHEN** `safeStorage` uses `basic_text`, a Webview posts traversal/script payloads, or a cursor expires during reconnect
- **THEN** key access throws `KEY_UNAVAILABLE`, malicious Webview payloads reject before reaching Core, and reconnect performs read-only `getSnapshot` with 0 auto-starts
