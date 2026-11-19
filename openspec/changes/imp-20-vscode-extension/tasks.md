# Tasks

- [x] Create `openspec/changes/imp-20-vscode-extension/` specification and design docs.
- [x] Implement `apps/vscode-extension/package.json` manifest (`publisher.name`, `vscode >= 1.85.0`, trust & virtual-workspace capabilities).
- [x] Implement `src/secret_vault.mjs`, `src/environment_guard.mjs`, `src/webview_bridge.mjs`, `src/extension_controller.mjs`, and `src/extension.mjs`.
- [x] Implement `apps/vscode-extension/tests/vscode_extension.test.mjs` covering V-14, P2, P8 remote/Restricted blocking, `basic_text` failure, malicious Webview rejection, trust revocation, Noise IK, and `CURSOR_EXPIRED` snapshot recovery.
- [x] Run `openspec validate imp-20-vscode-extension --strict` and `node --test`, record evidence in `docs/imp-20-vscode-evidence.md`, and comment on GitHub issue `#20`.
