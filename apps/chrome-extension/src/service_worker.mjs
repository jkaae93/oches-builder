import { ChromeWebCryptoVault } from './key_vault.mjs';
import { ChromeWorkerController } from './worker_controller.mjs';

export function createBrowserServiceWorker({
  chromeApi = globalThis.chrome,
  clientID,
  coreID,
  coreNoiseStaticPubRaw,
  localNoiseStaticPrivRaw,
  enrollmentGeneration = 1,
}) {
  if (!chromeApi?.runtime) {
    return null;
  }

  const vault = new ChromeWebCryptoVault();
  const controller = new ChromeWorkerController({
    runtimeId: chromeApi.runtime.id,
    clientID,
    coreID,
    coreNoiseStaticPubRaw,
    localNoiseStaticPrivRaw,
    enrollmentGeneration,
    keyVault: vault,
    connectNative: (hostName) => chromeApi.runtime.connectNative(hostName),
    sendNativeMessage: chromeApi.runtime.sendNativeMessage,
  });

  chromeApi.runtime.onMessage.addListener((message, sender, sendResponse) => {
    try {
      const staged = controller.handleContentMessage(message, sender);
      sendResponse({ ok: true, selection: staged });
    } catch (err) {
      sendResponse({ ok: false, code: err.code ?? 'REJECTED', error: err.message });
    }
    return false;
  });

  chromeApi.tabs?.onUpdated?.addListener((tabId, changeInfo) => {
    controller.handleTabUpdated(tabId, changeInfo);
  });

  chromeApi.tabs?.onRemoved?.addListener((tabId) => {
    controller.handleTabRemoved(tabId);
  });

  chromeApi.permissions?.onRemoved?.addListener((removed) => {
    controller.handlePermissionsRemoved(removed?.origins ?? []);
  });

  return controller;
}
