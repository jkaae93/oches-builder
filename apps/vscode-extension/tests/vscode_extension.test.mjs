import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { NoiseIKResponderHandshake, computeNoisePrologueHash } from '../../../core/contracts/noise_ik_client.mjs';
import { x25519PublicFromPrivate } from '../../../core/contracts/noise_ik_reference.mjs';
import { VSCodeSecretVault, VSCODE_PUBLISHER_ID } from '../src/secret_vault.mjs';
import { VSCodeExtensionController } from '../src/extension_controller.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const APP_ROOT = path.resolve(HERE, '..');

function createMemorySecretStorage() {
  const map = new Map();
  return {
    async store(k, v) {
      map.set(k, v);
    },
    async get(k) {
      return map.get(k) ?? undefined;
    },
    async delete(k) {
      map.delete(k);
    },
    dumpKeys: () => [...map.keys()],
  };
}

function createMockCoreTransport({
  coreNoisePrivRaw,
  enrolledClients,
  onCommand,
  supportedMinors = [0, 1],
}) {
  let activeSession = null;
  return {
    observedCalls: [],
    async negotiateVersion({ protocolMajor, minMinor, maxMinor }) {
      const overlap = Math.min(maxMinor, supportedMinors[1]);
      if (protocolMajor !== 1 || overlap < Math.max(minMinor, supportedMinors[0])) {
        return { protocolMajor: 2, selectedMinor: 0 };
      }
      return { protocolMajor: 1, selectedMinor: overlap };
    },
    async exchangeHandshake({ clientID, protocolMajor, msg1Base64 }) {
      const rec = enrolledClients.get(clientID);
      const prologueHash = computeNoisePrologueHash({
        protocolMajor,
        coreID: rec.coreID,
        clientID,
        enrollmentGeneration: rec.enrollmentGeneration,
        clientRole: 'vscode-extension',
      });
      const resp = new NoiseIKResponderHandshake({
        localStaticPrivRaw: coreNoisePrivRaw,
        prologueHash,
      });
      resp.readMessage1(Buffer.from(msg1Base64, 'base64'), (rsPub) => {
        if (rsPub.toString('base64') !== rec.noiseStaticPublicKeyBase64) {
          throw new Error('STATIC_KEY_MISMATCH');
        }
      });
      const out = resp.writeMessage2();
      activeSession = out.session;
      return { msg2Base64: out.message.toString('base64') };
    },
    async sendEncryptedFrames(framesBase64) {
      let assembled = null;
      for (const b64 of framesBase64) {
        const part = activeSession.receiveFrame(Buffer.from(b64, 'base64'), {
          require4KiBPadding: true,
        });
        if (part !== null) assembled = part;
      }
      const cmd = JSON.parse(assembled.toString('utf8'));
      this.observedCalls.push(cmd);
      const replyObj = onCommand(cmd);
      return activeSession
        .sendMessage(Buffer.from(JSON.stringify(replyObj), 'utf8'), { padTo4KiB: true })
        .map((buf) => buf.toString('base64'));
    },
  };
}

test('IMP-20.1: package.json enforces P2 vscode >=1.85.0, publisher.name, local workspace, and enablement guards', () => {
  const pkg = JSON.parse(fs.readFileSync(path.join(APP_ROOT, 'package.json'), 'utf8'));
  assert.equal(`${pkg.publisher}.${pkg.name}`, VSCODE_PUBLISHER_ID);
  assert.equal(pkg.engines.vscode, '^1.85.0');
  assert.deepEqual(pkg.extensionKind, ['workspace']);
  assert.equal(pkg.capabilities.virtualWorkspaces.supported, false);
  assert.equal(pkg.capabilities.untrustedWorkspaces.supported, 'limited');

  const gatedCmds = pkg.contributes.commands.filter((c) => c.command !== 'oches.getStatus');
  assert.ok(gatedCmds.length >= 3);
  for (const cmd of gatedCmds) {
    assert.equal(cmd.enablement, 'workspaceTrusted && !remoteName');
  }
});

test('IMP-20.2: SecretStorage rejects basic_text fallback with KEY_UNAVAILABLE and zero plaintext fallback', async () => {
  const weakVault = new VSCodeSecretVault({
    secretStorage: createMemorySecretStorage(),
    safeStorageBackend: 'basic_text',
  });
  await assert.rejects(
    () => weakVault.generateAndStoreEnrollmentKeys('vscode-1'),
    (err) => err.code === 'KEY_UNAVAILABLE'
  );

  const missingVault = new VSCodeSecretVault({ secretStorage: null });
  await assert.rejects(() => missingVault.loadKeys('vscode-1'), (err) => err.code === 'KEY_UNAVAILABLE');

  const keychainVault = new VSCodeSecretVault({
    secretStorage: createMemorySecretStorage(),
    safeStorageBackend: 'keychain',
  });
  const enrolled = await keychainVault.generateAndStoreEnrollmentKeys('vscode-1');
  assert.equal(enrolled.trustLevel, 'USER_ENROLLED_KEY');
  assert.equal(enrolled.sharedHostIsolationGuaranteed, false);
});

test('IMP-20.3 & V-14: Restricted Mode, Remote SSH/WSL/Container/Web, and trust revocation block direct commands with 0 Core calls', async () => {
  const coreNoisePrivRaw = Buffer.from('33'.repeat(32), 'hex');
  const coreNoisePub = x25519PublicFromPrivate(coreNoisePrivRaw);
  const secrets = createMemorySecretStorage();
  const vault = new VSCodeSecretVault({ secretStorage: secrets, safeStorageBackend: 'keychain' });
  const enrolled = await vault.generateAndStoreEnrollmentKeys('vscode-1');

  const clients = new Map([
    [
      'vscode-1',
      {
        coreID: 'core-local-1',
        enrollmentGeneration: 1,
        noiseStaticPublicKeyBase64: enrolled.noiseStaticPublicKeyBase64,
      },
    ],
  ]);

  const transport = createMockCoreTransport({
    coreNoisePrivRaw,
    enrolledClients: clients,
    onCommand: (cmd) => ({ ok: true, op: cmd.operation }),
  });

  // Start in Restricted Mode (untrusted local workspace)
  const controller = new VSCodeExtensionController({
    clientID: 'vscode-1',
    coreID: 'core-local-1',
    coreNoiseStaticPubRaw: coreNoisePub,
    secretVault: vault,
    coreTransport: transport,
    initialEnvironment: {
      remoteName: '',
      uiKind: 'Desktop',
      workspaceFolders: [{ uri: { scheme: 'file', fsPath: '/Users/dev/project' } }],
      isTrusted: false,
    },
  });

  await controller.connectAndNegotiate();

  // Direct command invocation in Restricted Mode fails BEFORE touching Core transport
  for (const op of ['analyzeWorkspace', 'applyPlan', 'startRun', 'sendExternalContext']) {
    await assert.rejects(
      () => controller.executeCommand(op, { workspaceID: 'ws-1' }),
      (err) => err.code === 'RESTRICTED_MODE_DENIED'
    );
  }
  assert.equal(transport.observedCalls.length, 0);

  // Grant trust -> analyzeWorkspace succeeds over Noise IK
  controller.onWorkspaceTrustChanged(true);
  const res = await controller.executeCommand('analyzeWorkspace', {
    workspaceID: 'ws-1',
    expectedRevision: 'rev-1',
  });
  assert.equal(res.ok, true);
  assert.equal(transport.observedCalls.length, 1);

  // Revoke trust OR move to non-file/remote -> immediately blocks again
  controller.onWorkspaceTrustChanged(false);
  await assert.rejects(
    () => controller.executeCommand('applyPlan', { workspaceID: 'ws-1' }),
    (err) => err.code === 'RESTRICTED_MODE_DENIED'
  );
  assert.equal(transport.observedCalls.length, 1);

  for (const env of [
    { remoteName: 'ssh-remote', uiKind: 'Desktop', isTrusted: true },
    { remoteName: 'wsl', uiKind: 'Desktop', isTrusted: true },
    { remoteName: 'dev-container', uiKind: 'Desktop', isTrusted: true },
    { remoteName: '', uiKind: 'Web', isTrusted: true },
    { remoteName: '', uiKind: 'Desktop', workspaceFolders: [{ scheme: 'vscode-vfs' }], isTrusted: true },
  ]) {
    controller.refreshEnvironment(env);
    assert.equal(controller.environment.status, 'UNSUPPORTED');
    await assert.rejects(
      () => controller.executeCommand('analyzeWorkspace', { workspaceID: 'ws-1' }),
      (err) => err.code === 'REMOTE_UNSUPPORTED'
    );
  }
  assert.equal(transport.observedCalls.length, 1);
});

test('IMP-20.4: Webview CSP/nonce, HTML escaping, credential omission, malicious payload rejection, and CURSOR_EXPIRED snapshot recovery', async () => {
  const coreNoisePrivRaw = Buffer.from('33'.repeat(32), 'hex');
  const coreNoisePub = x25519PublicFromPrivate(coreNoisePrivRaw);
  const vault = new VSCodeSecretVault({
    secretStorage: createMemorySecretStorage(),
    safeStorageBackend: 'keychain',
  });
  const enrolled = await vault.generateAndStoreEnrollmentKeys('vscode-2');
  const clients = new Map([
    [
      'vscode-2',
      {
        coreID: 'core-local-1',
        enrollmentGeneration: 1,
        noiseStaticPublicKeyBase64: enrolled.noiseStaticPublicKeyBase64,
      },
    ],
  ]);

  let cursorExpiredOnce = false;
  const transport = createMockCoreTransport({
    coreNoisePrivRaw,
    enrolledClients: clients,
    onCommand: (cmd) => {
      if (cmd.operation === 'inspectSnapshot' && cmd.payload?.cursor === 10 && !cursorExpiredOnce) {
        cursorExpiredOnce = true;
        return { error: 'CURSOR_EXPIRED' };
      }
      if (cmd.operation === 'inspectSnapshot' && cmd.payload?.fullSnapshot === true) {
        return { ok: true, nextCursor: 88, runs: [{ runId: 'run-1', status: 'Running' }] };
      }
      return { ok: true, op: cmd.operation };
    },
  });

  const controller = new VSCodeExtensionController({
    clientID: 'vscode-2',
    coreID: 'core-local-1',
    coreNoiseStaticPubRaw: coreNoisePub,
    secretVault: vault,
    coreTransport: transport,
    initialEnvironment: {
      remoteName: '',
      uiKind: 'Desktop',
      workspaceFolders: [{ scheme: 'file', fsPath: '/Users/dev/project' }],
      isTrusted: true,
    },
  });
  controller.lastCursor = 10;

  const conn = await controller.connectAndNegotiate();
  assert.equal(conn.trustLevel, 'USER_ENROLLED_KEY');
  assert.equal(conn.publisherExtensionId, VSCODE_PUBLISHER_ID);

  // Webview escapes project text as data and sets strict nonce CSP
  const html = controller.renderWebview({
    nonce: 'fixed-nonce-123',
    cspSource: 'vscode-webview:',
    projectSnippet: '<script>stealTokens()</script>',
  });
  assert.ok(html.includes("default-src 'none'; script-src 'nonce-fixed-nonce-123'"));
  assert.ok(html.includes('&lt;script&gt;stealTokens()&lt;/script&gt;'));
  assert.ok(!html.includes(enrolled.noiseStaticPublicKeyBase64));

  // Malicious Webview messages rejected
  await assert.rejects(
    () =>
      controller.handleWebviewMessage(
        { webviewId: 'wv-1', op: 'proposeAnalyze', targetUri: '../../etc/passwd' },
        { expectedWebviewId: 'wv-1' }
      ),
    (err) => err.code === 'MALICIOUS_WEBVIEW_MESSAGE'
  );
  await assert.rejects(
    () =>
      controller.handleWebviewMessage(
        { webviewId: 'wv-1', op: 'execArbitraryCommand' },
        { expectedWebviewId: 'wv-1' }
      ),
    (err) => err.code === 'MALICIOUS_WEBVIEW_MESSAGE'
  );
  await assert.rejects(
    () =>
      controller.handleWebviewMessage(
        { webviewId: 'wrong-wv', op: 'requestStatus' },
        { expectedWebviewId: 'wv-1' }
      ),
    (err) => err.code === 'UNTRUSTED_WEBVIEW_SENDER'
  );

  // CURSOR_EXPIRED triggers read-only full snapshot sync with 0 auto-starts
  const recovery = await controller.pollCursorOrRecoverSnapshot();
  assert.equal(recovery.recoveredFromCursorExpiry, true);
  assert.equal(recovery.autoStartedRunsCount, 0);
  assert.equal(controller.lastCursor, 88);
  assert.equal(recovery.snapshot.runs[0].status, 'Running');
});
