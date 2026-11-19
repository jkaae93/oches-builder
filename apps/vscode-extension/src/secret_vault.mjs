import crypto from 'node:crypto';
import { x25519PublicFromPrivate } from '../../../core/contracts/noise_ik_reference.mjs';

export const VSCODE_PUBLISHER_ID = 'oches.oches-builder';
const UNSAFE_SAFE_STORAGE_BACKENDS = new Set(['basic_text', 'unknown', 'none', '']);

export class VSCodeSecretVaultError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

export class VSCodeSecretVault {
  constructor({
    secretStorage,
    safeStorageBackend = 'keychain',
    extensionId = VSCODE_PUBLISHER_ID,
  } = {}) {
    this.secretStorage = secretStorage ?? null;
    this.safeStorageBackend = safeStorageBackend;
    this.extensionId = extensionId;
  }

  #assertSecureStorage() {
    if (!this.secretStorage || typeof this.secretStorage.get !== 'function' || typeof this.secretStorage.store !== 'function') {
      throw new VSCodeSecretVaultError('KEY_UNAVAILABLE', 'ExtensionContext.secrets is unavailable');
    }
    if (UNSAFE_SAFE_STORAGE_BACKENDS.has(this.safeStorageBackend)) {
      throw new VSCodeSecretVaultError(
        'KEY_UNAVAILABLE',
        `Refusing unencrypted safeStorage backend (${this.safeStorageBackend}); no globalState/workspaceState fallback`
      );
    }
  }

  async generateAndStoreEnrollmentKeys(clientID) {
    this.#assertSecureStorage();
    if (!clientID || typeof clientID !== 'string') {
      throw new VSCodeSecretVaultError('INVALID_CLIENT', 'clientID required');
    }

    const { publicKey: sigPub, privateKey: sigPriv } = crypto.generateKeyPairSync('ed25519');
    const sigPrivDer = sigPriv.export({ format: 'der', type: 'pkcs8' });
    const sigPubDer = sigPub.export({ format: 'der', type: 'spki' });

    const noisePrivRaw = crypto.randomBytes(32);
    const noisePubRaw = x25519PublicFromPrivate(noisePrivRaw);

    const serializedRecord = {
      keyId: `vscode-keys:${clientID}`,
      clientID,
      extensionId: this.extensionId,
      trustLevel: 'USER_ENROLLED_KEY',
      // Shared Extension Host processes cannot hardware-isolate secrets from co-hosted extensions.
      sharedHostIsolationGuaranteed: false,
      signingPublicKeyBase64: sigPubDer.subarray(sigPubDer.length - 32).toString('base64'),
      signingPrivateKeyPkcs8Base64: sigPrivDer.toString('base64'),
      noiseStaticPublicKeyBase64: noisePubRaw.toString('base64'),
      noiseStaticPrivateRawBase64: noisePrivRaw.toString('base64'),
    };

    await this.secretStorage.store(
      serializedRecord.keyId,
      JSON.stringify(serializedRecord)
    );

    return {
      keyId: serializedRecord.keyId,
      clientID,
      extensionId: this.extensionId,
      trustLevel: serializedRecord.trustLevel,
      sharedHostIsolationGuaranteed: false,
      signingPublicKeyBase64: serializedRecord.signingPublicKeyBase64,
      noiseStaticPublicKeyBase64: serializedRecord.noiseStaticPublicKeyBase64,
    };
  }

  async loadKeys(clientID) {
    this.#assertSecureStorage();
    const raw = await this.secretStorage.get(`vscode-keys:${clientID}`);
    if (!raw) {
      throw new VSCodeSecretVaultError('KEY_UNAVAILABLE', 'No enrolled key stored in ExtensionContext.secrets');
    }
    const parsed = JSON.parse(raw);
    return {
      ...parsed,
      noiseStaticPrivateRaw: Buffer.from(parsed.noiseStaticPrivateRawBase64, 'base64'),
      signingPrivateKey: crypto.createPrivateKey({
        key: Buffer.from(parsed.signingPrivateKeyPkcs8Base64, 'base64'),
        format: 'der',
        type: 'pkcs8',
      }),
    };
  }

  async deleteKeys(clientID) {
    this.#assertSecureStorage();
    await this.secretStorage.delete(`vscode-keys:${clientID}`);
  }
}
