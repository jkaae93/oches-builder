const DEFAULT_DB_NAME = 'oches-extension-vault';
const DEFAULT_STORE_NAME = 'device-keys';

export class KeyVaultError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

export class IndexedDBKeyStore {
  constructor(indexedDBFactory = globalThis.indexedDB, dbName = DEFAULT_DB_NAME) {
    this.indexedDB = indexedDBFactory ?? null;
    this.dbName = dbName;
  }

  #openDB() {
    if (!this.indexedDB || typeof this.indexedDB.open !== 'function') {
      return Promise.reject(new KeyVaultError('KEY_UNAVAILABLE', 'IndexedDB is unavailable'));
    }
    return new Promise((resolve, reject) => {
      const req = this.indexedDB.open(this.dbName, 1);
      req.onupgradeneeded = () => {
        const db = req.result;
        if (!db.objectStoreNames.contains(DEFAULT_STORE_NAME)) {
          db.createObjectStore(DEFAULT_STORE_NAME, { keyPath: 'keyId' });
        }
      };
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => reject(new KeyVaultError('KEY_UNAVAILABLE', 'IndexedDB open failed'));
    });
  }

  async put(record) {
    const db = await this.#openDB();
    return new Promise((resolve, reject) => {
      const tx = db.transaction([DEFAULT_STORE_NAME], 'readwrite');
      const store = tx.objectStore(DEFAULT_STORE_NAME);
      const req = store.put(record);
      req.onsuccess = () => resolve();
      req.onerror = () => reject(new KeyVaultError('KEY_UNAVAILABLE', 'IndexedDB write failed'));
    });
  }

  async get(keyId) {
    const db = await this.#openDB();
    return new Promise((resolve, reject) => {
      const tx = db.transaction([DEFAULT_STORE_NAME], 'readonly');
      const store = tx.objectStore(DEFAULT_STORE_NAME);
      const req = store.get(keyId);
      req.onsuccess = () => resolve(req.result ?? null);
      req.onerror = () => reject(new KeyVaultError('KEY_UNAVAILABLE', 'IndexedDB read failed'));
    });
  }

  async delete(keyId) {
    const db = await this.#openDB();
    return new Promise((resolve, reject) => {
      const tx = db.transaction([DEFAULT_STORE_NAME], 'readwrite');
      const store = tx.objectStore(DEFAULT_STORE_NAME);
      const req = store.delete(keyId);
      req.onsuccess = () => resolve();
      req.onerror = () => reject(new KeyVaultError('KEY_UNAVAILABLE', 'IndexedDB delete failed'));
    });
  }
}

export class ChromeWebCryptoVault {
  constructor({
    subtle = globalThis.crypto?.subtle ?? null,
    keyStore = new IndexedDBKeyStore(),
  } = {}) {
    this.subtle = subtle;
    this.keyStore = keyStore;
  }

  #requireCryptoAndStore() {
    if (!this.subtle || !this.keyStore) {
      throw new KeyVaultError('KEY_UNAVAILABLE', 'WebCrypto or KeyStore is unavailable');
    }
    if (typeof this.keyStore.isAvailable === 'function' && !this.keyStore.isAvailable()) {
      throw new KeyVaultError('KEY_UNAVAILABLE', 'IndexedDB storage is unavailable');
    }
  }

  async generateAndStoreEnrollmentKeys(clientID) {
    this.#requireCryptoAndStore();
    if (!clientID || typeof clientID !== 'string') {
      throw new KeyVaultError('INVALID_CLIENT', 'clientID required');
    }

    // Separate purposes cleanly: Ed25519 signing + X25519 Noise key agreement.
    // Both private CryptoKeys are marked extractable = false (non-exportable via JS).
    const signingPair = await this.subtle.generateKey(
      { name: 'Ed25519' },
      false,
      ['sign', 'verify']
    );
    const noisePair = await this.subtle.generateKey(
      { name: 'X25519' },
      false,
      ['deriveBits']
    );

    if (signingPair.privateKey.extractable !== false || noisePair.privateKey.extractable !== false) {
      throw new KeyVaultError('KEY_UNAVAILABLE', 'Non-extractable CryptoKey requirement violated');
    }

    const signingPubSpki = Buffer.from(await this.subtle.exportKey('spki', signingPair.publicKey));
    const noisePubSpki = Buffer.from(await this.subtle.exportKey('spki', noisePair.publicKey));

    const record = {
      keyId: `chrome-keys:${clientID}`,
      clientID,
      signingPublicKeyBase64: signingPubSpki.subarray(signingPubSpki.length - 32).toString('base64'),
      noiseStaticPublicKeyBase64: noisePubSpki.subarray(noisePubSpki.length - 32).toString('base64'),
      signingPrivateKey: signingPair.privateKey,
      noisePrivateKey: noisePair.privateKey,
      createdAtEpochMs: Date.now(),
    };

    try {
      await this.keyStore.put(record);
    } catch (err) {
      throw new KeyVaultError('KEY_UNAVAILABLE', `Failed storing keys without fallback: ${err.message}`);
    }

    return {
      keyId: record.keyId,
      clientID,
      signingPublicKeyBase64: record.signingPublicKeyBase64,
      noiseStaticPublicKeyBase64: record.noiseStaticPublicKeyBase64,
      nonExtractable: true,
    };
  }

  async loadKeys(clientID) {
    this.#requireCryptoAndStore();
    const record = await this.keyStore.get(`chrome-keys:${clientID}`);
    if (!record || !record.signingPrivateKey || !record.noisePrivateKey) {
      throw new KeyVaultError('KEY_UNAVAILABLE', 'Enrolled keys missing in IndexedDB');
    }
    if (record.signingPrivateKey.extractable !== false || record.noisePrivateKey.extractable !== false) {
      throw new KeyVaultError('KEY_UNAVAILABLE', 'Stored private key is unexpectedly extractable');
    }
    return record;
  }

  async signCanonicalDigest(clientID, canonicalBytes) {
    const record = await this.loadKeys(clientID);
    const sig = await this.subtle.sign(
      { name: 'Ed25519' },
      record.signingPrivateKey,
      canonicalBytes
    );
    return Buffer.from(sig).toString('base64');
  }

  async clearKeys(clientID) {
    this.#requireCryptoAndStore();
    await this.keyStore.delete(`chrome-keys:${clientID}`);
  }
}
