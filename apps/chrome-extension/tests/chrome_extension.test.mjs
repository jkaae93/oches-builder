import test from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  NativeFrameDecoder,
  NativeHostBridge,
  encodeNativeFrame,
  validateNativeManifest,
} from '../native-host/host_bridge.mjs';
import { ChromeWebCryptoVault } from '../src/key_vault.mjs';
import { buildUntrustedSelectionPayload } from '../src/content_script.mjs';
import { ChromeWorkerController, NATIVE_HOST_NAME } from '../src/worker_controller.mjs';
import { renderSidePanelState } from '../src/sidepanel.mjs';
import { x25519PublicFromPrivate } from '../../../core/contracts/noise_ik_reference.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const APP_ROOT = path.resolve(HERE, '..');
const ALLOWED_ORIGIN = 'chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/';
const RUNTIME_ID = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

function createMemoryIndexedStore({ available = true } = {}) {
  const entries = new Map();
  return {
    isAvailable: () => available,
    async put(rec) {
      if (!available) throw new Error('store unavailable');
      entries.set(rec.keyId, rec);
    },
    async get(keyId) {
      if (!available) throw new Error('store unavailable');
      return entries.get(keyId) ?? null;
    },
    async delete(keyId) {
      entries.delete(keyId);
    },
  };
}

function createFramedNativePort(bridge, originArg) {
  bridge.open(['/Applications/Oches.app/Contents/Helpers/oches-native-host', originArg]);
  const msgListeners = [];
  const discListeners = [];
  let closed = false;
  return {
    postMessage(obj) {
      if (closed) throw new Error('PORT_DISCONNECTED');
      const framed = encodeNativeFrame(obj);
      const replies = bridge.handleChunk(framed);
      for (const reply of replies) {
        const encodedReply = encodeNativeFrame(reply);
        const decoder = new NativeFrameDecoder();
        for (const decodedReply of decoder.push(encodedReply)) {
          queueMicrotask(() => {
            for (const fn of msgListeners) fn(decodedReply);
          });
        }
      }
    },
    disconnect() {
      if (!closed) {
        closed = true;
        bridge.close();
        for (const fn of discListeners) fn();
      }
    },
    onMessage: { addListener: (fn) => msgListeners.push(fn) },
    onDisconnect: { addListener: (fn) => discListeners.push(fn) },
  };
}

test('IMP-19.1: MV3 manifest, Chrome P2 min version, and Native Host allowed_origins validation', () => {
  const extManifest = JSON.parse(fs.readFileSync(path.join(APP_ROOT, 'manifest.json'), 'utf8'));
  assert.equal(extManifest.manifest_version, 3);
  assert.ok(Number(extManifest.minimum_chrome_version) >= 120);
  assert.ok(extManifest.permissions.includes('nativeMessaging'));
  assert.ok(!extManifest.permissions.includes('<all_urls>'));
  assert.equal(extManifest.host_permissions, undefined);

  const hostManifest = JSON.parse(
    fs.readFileSync(path.join(APP_ROOT, 'native-host/com.oches.builder.host.template.json'), 'utf8')
  );
  assert.deepEqual(validateNativeManifest(hostManifest).allowed_origins, [ALLOWED_ORIGIN]);

  assert.throws(
    () =>
      validateNativeManifest({
        ...hostManifest,
        allowed_origins: ['chrome-extension://*/'],
      }),
    /INVALID_MANIFEST/
  );
  assert.throws(
    () =>
      validateNativeManifest({
        ...hostManifest,
        extraUnexpected: true,
      }),
    /UNKNOWN_FIELD/
  );
});

test('IMP-19.2: Native Host checks argv[1] origin, rejects body spoof & >256KiB W1/P7 frames, classifies USER_ENROLLED_KEY', () => {
  const hostManifest = JSON.parse(
    fs.readFileSync(path.join(APP_ROOT, 'native-host/com.oches.builder.host.template.json'), 'utf8')
  );
  const bridge = new NativeHostBridge({ manifest: hostManifest });

  assert.throws(() => bridge.open(['oches-native-host']), /MISSING_CALLER_ORIGIN/);
  assert.throws(
    () => bridge.open(['oches-native-host', 'chrome-extension://bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/']),
    /ORIGIN_NOT_ALLOWED/
  );

  const openInfo = bridge.open(['oches-native-host', ALLOWED_ORIGIN]);
  assert.equal(openInfo.trustLevel, 'USER_ENROLLED_KEY');
  assert.equal(openInfo.directExecutionUnproven, true);

  assert.throws(
    () =>
      bridge.handleChunk(
        encodeNativeFrame({
          op: 'ping',
          callerOrigin: 'chrome-extension://bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/',
        })
      ),
    /ORIGIN_MISMATCH/
  );

  assert.throws(
    () => bridge.handleChunk(encodeNativeFrame({ op: 'exec_shell', cmd: 'id' })),
    /UNSUPPORTED_ENVELOPE_OP/
  );

  // Crafted 262,145-byte frame header fails BEFORE reading payload bytes (W1/P7).
  const badHdr = Buffer.alloc(10);
  badHdr.writeUInt32LE(262_145, 0);
  badHdr.write('{"op":', 4, 'utf8');
  assert.throws(() => bridge.handleChunk(badHdr), /FRAME_SIZE_EXCEEDED/);
});

test('IMP-19.3: WebCrypto key vault generates non-extractable keys and fails closed with KEY_UNAVAILABLE', async () => {
  const vault = new ChromeWebCryptoVault({ keyStore: createMemoryIndexedStore({ available: true }) });
  const enrolled = await vault.generateAndStoreEnrollmentKeys('chrome-client-1');
  assert.equal(enrolled.nonExtractable, true);

  const loaded = await vault.loadKeys('chrome-client-1');
  assert.equal(loaded.signingPrivateKey.extractable, false);
  assert.equal(loaded.noisePrivateKey.extractable, false);
  await assert.rejects(() => globalThis.crypto.subtle.exportKey('pkcs8', loaded.signingPrivateKey));

  const sig = await vault.signCanonicalDigest('chrome-client-1', Buffer.from('digest-v1'));
  assert.ok(sig.length > 0);

  const unavailableVault = new ChromeWebCryptoVault({
    keyStore: createMemoryIndexedStore({ available: false }),
  });
  await assert.rejects(
    () => unavailableVault.generateAndStoreEnrollmentKeys('chrome-client-2'),
    (err) => err.code === 'KEY_UNAVAILABLE'
  );
  await assert.rejects(
    () => unavailableVault.loadKeys('chrome-client-1'),
    (err) => err.code === 'KEY_UNAVAILABLE'
  );
});

test('IMP-19.4 & V-14/V-21: Content script spoofing stripped, stale on navigation, 2-step confirmation, Noise IK + Worker restart read-only sync', async () => {
  const coreNoisePriv = Buffer.from('33'.repeat(32), 'hex');
  const coreNoisePub = x25519PublicFromPrivate(coreNoisePriv);
  const clientNoisePriv = Buffer.from('11'.repeat(32), 'hex');
  const clientNoisePub = x25519PublicFromPrivate(clientNoisePriv);

  const observedCoreCalls = [];
  let currentCursor = 42;
  const hostManifest = JSON.parse(
    fs.readFileSync(path.join(APP_ROOT, 'native-host/com.oches.builder.host.template.json'), 'utf8')
  );
  const bridge = new NativeHostBridge({
    manifest: hostManifest,
    coreNoiseStaticPrivRaw: coreNoisePriv,
    coreBridge: {
      lookupEnrolledClient: (clientID) =>
        clientID === 'chrome-profile-1'
          ? {
              coreID: 'core-local-1',
              clientID: 'chrome-profile-1',
              enrollmentGeneration: 1,
              clientRole: 'chrome-extension',
              noiseStaticPublicKeyBase64: clientNoisePub.toString('base64'),
              revoked: false,
            }
          : null,
      handleDecryptedCommand: (command, attribution) => {
        observedCoreCalls.push({ command, attribution });
        if (command.operation === 'inspectState') {
          return {
            ok: true,
            nextCursor: currentCursor,
            activeAttempt: { attemptId: 'att-1', status: 'Running' },
          };
        }
        if (command.operation === 'proposeAction') {
          // Even valid proposal over Noise IK from USER_ENROLLED_KEY requires Desktop approval before execution.
          return {
            ok: true,
            status: 'APPROVAL_REQUIRED',
            proposalId: 'prop-99',
            trustLevel: attribution.trustLevel,
          };
        }
        return { ok: false, error: 'DENIED' };
      },
    },
  });

  const vault = new ChromeWebCryptoVault({ keyStore: createMemoryIndexedStore({ available: true }) });
  await vault.generateAndStoreEnrollmentKeys('chrome-profile-1');

  let activePort = null;
  const controller = new ChromeWorkerController({
    runtimeId: RUNTIME_ID,
    clientID: 'chrome-profile-1',
    coreID: 'core-local-1',
    coreNoiseStaticPubRaw: coreNoisePub,
    localNoiseStaticPrivRaw: clientNoisePriv,
    enrollmentGeneration: 1,
    keyVault: vault,
    connectNative: (name) => {
      assert.equal(name, NATIVE_HOST_NAME);
      activePort = createFramedNativePort(bridge, ALLOWED_ORIGIN);
      return activePort;
    },
  });

  // External unknown extension message rejected
  assert.throws(
    () =>
      controller.handleContentMessage(
        buildUntrustedSelectionPayload({ selectionText: 'hello' }),
        { id: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', origin: 'https://example.com', tab: { id: 1 }, frameId: 0 }
      ),
    (err) => err.code === 'EXTERNAL_SENDER_DENIED'
  );

  // Malicious page claims spoofed origin, tabId, and pre-approved flags -> stripped/overridden by sender metadata
  const rawPayload = {
    ...buildUntrustedSelectionPayload({
      selectionText: 'Selected <script>alert(1)</script> snippet',
      pageTitle: 'Example Doc',
      approved: true,
      origin: 'https://trusted-internal.example',
      tabId: 999,
      execute: true,
    }),
    origin: 'https://trusted-internal.example',
    tabId: 999,
    approved: true,
    execute: true,
  };
  const staged = controller.handleContentMessage(rawPayload, {
    id: RUNTIME_ID,
    origin: 'https://untrusted.example',
    url: 'https://untrusted.example/docs/1',
    tab: { id: 7 },
    frameId: 0,
    documentId: 'doc-1',
  });
  assert.equal(staged.origin, 'https://untrusted.example');
  assert.equal(staged.tabId, 7);
  assert.equal(staged.stale, false);
  assert.equal(staged.confirmedForTransfer, false);
  assert.equal('approved' in staged, false);

  // Side Panel renders strictly via textContent (never HTML-executing selection text)
  const domElements = Object.fromEntries(
    ['trust-badge', 'connection-status', 'selection-origin', 'selection-stale-status', 'selection-preview', 'confirm-transfer-btn'].map(
      (id) => [id, { textContent: '', disabled: false }]
    )
  );
  renderSidePanelState({ getElementById: (id) => domElements[id] }, { connected: false, activeSelection: staged });
  assert.equal(domElements['selection-preview'].textContent, 'Selected <script>alert(1)</script> snippet');
  assert.equal(domElements['confirm-transfer-btn'].disabled, false);

  // Stateful sendNativeMessage rejected
  assert.throws(
    () => controller.sendStatefulViaSendNativeMessage(),
    (err) => err.code === 'SEND_NATIVE_MESSAGE_FORBIDDEN_FOR_STATEFUL_SESSION'
  );

  await controller.connectAndHandshake();

  // Cannot send before explicit Side Panel confirmation (2-step collection vs transfer separation)
  await assert.rejects(
    () => controller.submitProposalToCore(staged.selectionId, { workspaceID: 'ws-1' }),
    (err) => err.code === 'TRANSFER_CONFIRMATION_REQUIRED'
  );

  controller.confirmSelectionInSidePanel(staged.selectionId);
  const proposalResp = await controller.submitProposalToCore(staged.selectionId, { workspaceID: 'ws-1' });
  assert.equal(proposalResp.status, 'APPROVAL_REQUIRED');
  assert.equal(proposalResp.trustLevel, 'USER_ENROLLED_KEY');

  // Navigation marks selection stale and blocks further proposal reuse
  controller.handleTabUpdated(7, { url: 'https://attacker.example/phish' });
  assert.throws(
    () => controller.confirmSelectionInSidePanel(staged.selectionId),
    (err) => err.code === 'SELECTION_STALE_RESELECT_REQUIRED'
  );

  // Port disconnect / Service Worker restart recovery clears auth state, re-handshakes Noise IK,
  // marks unverified selections stale, and executes read-only inspectState only (0 auto-starts).
  activePort.disconnect();
  assert.equal(controller.connected, false);
  currentCursor = 55;
  const recovery = await controller.recoverAfterWorkerRestart();
  assert.equal(recovery.reauthenticated, true);
  assert.equal(recovery.readOnlySyncOnly, true);
  assert.equal(recovery.autoStartedRunsCount, 0);
  assert.equal(controller.lastCursor, 55);
  assert.equal(observedCoreCalls[observedCoreCalls.length - 1].command.operation, 'inspectState');
});
