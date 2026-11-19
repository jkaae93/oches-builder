import { VSCodeSecretVault } from './secret_vault.mjs';
import { VSCodeExtensionController } from './extension_controller.mjs';

export function activateVSCodeExtension({
  vscodeApi = null,
  context = null,
  coreID,
  coreNoiseStaticPubRaw,
  coreTransport,
  safeStorageBackend = 'keychain',
}) {
  if (!vscodeApi || !context) {
    return null;
  }

  const vault = new VSCodeSecretVault({
    secretStorage: context.secrets,
    safeStorageBackend,
  });

  const controller = new VSCodeExtensionController({
    clientID: context.globalState?.get?.('oches.clientID') ?? 'vscode-local-default',
    coreID,
    coreNoiseStaticPubRaw,
    secretVault: vault,
    coreTransport,
    initialEnvironment: {
      remoteName: vscodeApi.env?.remoteName ?? '',
      uiKind: vscodeApi.env?.uiKind ?? 'Desktop',
      workspaceFolders: vscodeApi.workspace?.workspaceFolders ?? [],
      isTrusted: vscodeApi.workspace?.isTrusted === true,
    },
  });

  context.subscriptions?.push?.(
    vscodeApi.workspace?.onDidGrantWorkspaceTrust?.(() => controller.onWorkspaceTrustChanged(true)),
    vscodeApi.workspace?.onDidChangeWorkspaceFolders?.(() =>
      controller.onWorkspaceFoldersChanged(
        vscodeApi.workspace?.workspaceFolders ?? [],
        vscodeApi.workspace?.isTrusted === true
      )
    )
  );

  return controller;
}

export function deactivate() {}
