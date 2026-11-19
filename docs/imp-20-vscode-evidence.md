# IMP-20 VS Code Local Extension Evidence

- **Issue**: `#20` (`[IMP-20] VS Code 로컬 Extension`)
- **OpenSpec**: [proposal.md](../openspec/changes/imp-20-vscode-extension/proposal.md) · [design.md](../openspec/changes/imp-20-vscode-extension/design.md) · [spec.md](../openspec/changes/imp-20-vscode-extension/specs/vscode-extension/spec.md)
- **Implementation**: [package.json](../apps/vscode-extension/package.json), [secret_vault.mjs](../apps/vscode-extension/src/secret_vault.mjs), [environment_guard.mjs](../apps/vscode-extension/src/environment_guard.mjs), [webview_bridge.mjs](../apps/vscode-extension/src/webview_bridge.mjs), [extension_controller.mjs](../apps/vscode-extension/src/extension_controller.mjs), [extension.mjs](../apps/vscode-extension/src/extension.mjs)
- **Verification Executed**:
  - `openspec validate imp-20-vscode-extension --strict` -> PASS (`Change 'imp-20-vscode-extension' is valid`)
  - `node --test apps/vscode-extension/tests/vscode_extension.test.mjs` -> 4/4 PASS
  - Verified controls: `vscode >= 1.85.0` (P2), `publisher.name` = `oches.oches-builder` explicitly mapped to `USER_ENROLLED_KEY` (`sharedHostIsolationGuaranteed: false`), `ExtensionContext.secrets` refusing `basic_text` fallback (`KEY_UNAVAILABLE`) with zero `globalState`/`workspaceState` fallback, Restricted Mode blocking both UI and direct command invocation (0 Core calls), live trust/folder re-evaluation, SSH/WSL/Dev Container/Web/non-`file:` host blocking (`REMOTE_UNSUPPORTED`, P8), Webview strict nonce CSP + HTML escaping + malicious traversal/script payload rejection + zero credential exposure, Noise IK version negotiation, and `CURSOR_EXPIRED` read-only snapshot recovery with 0 auto-starts (V-14).
- **Remaining Product Gates (`NOT RUN`)**:
  - Real VS Code Desktop Extension Host execution (macOS arm64): **NOT RUN**
  - Visual Studio Code Marketplace publisher verification & extension review: **NOT RUN**
  - Remote SSH / WSL / Dev Container support: **UNSUPPORTED in v1 (P8)**
