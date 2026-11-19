import crypto from 'node:crypto';
import {
  MAX_LOGICAL_MESSAGE_BYTES,
  NoiseIKInitiatorHandshake,
  computeNoisePrologueHash,
} from '../../../core/contracts/noise_ik_client.mjs';

export const NATIVE_HOST_NAME = 'com.oches.builder.host';

export class WorkerControllerError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

export class ChromeWorkerController {
  constructor({
    runtimeId,
    clientID,
    coreID,
    coreNoiseStaticPubRaw,
    localNoiseStaticPrivRaw,
    enrollmentGeneration = 1,
    protocolMajor = 1,
    clientRole = 'chrome-extension',
    keyVault,
    connectNative,
    sendNativeMessage = null,
    ephemeralFactory = null,
  }) {
    if (!runtimeId || !clientID || !coreID) {
      throw new WorkerControllerError('INVALID_CONFIG', 'runtimeId, clientID, coreID required');
    }
    this.runtimeId = runtimeId;
    this.clientID = clientID;
    this.coreID = coreID;
    this.coreNoiseStaticPubRaw = Buffer.from(coreNoiseStaticPubRaw);
    this.localNoiseStaticPrivRaw = Buffer.from(localNoiseStaticPrivRaw);
    this.enrollmentGeneration = enrollmentGeneration;
    this.protocolMajor = protocolMajor;
    this.clientRole = clientRole;
    this.keyVault = keyVault;
    this.connectNative = connectNative;
    this.sendNativeMessage = sendNativeMessage;
    this.ephemeralFactory = ephemeralFactory;

    this.connected = false;
    this.port = null;
    this.noiseSession = null;
    this.lastCursor = 0;
    this.selections = new Map();
    this.selectionCounter = 0;
    this.autoStartedRunsCount = 0;
    this.pendingPortResponses = [];
  }

  #resolveSenderOrigin(sender) {
    if (sender.origin && typeof sender.origin === 'string') {
      return sender.origin;
    }
    if (sender.url && typeof sender.url === 'string') {
      try {
        return new URL(sender.url).origin;
      } catch {
        return null;
      }
    }
    return null;
  }

  handleContentMessage(rawPayload, sender) {
    if (!sender || sender.id !== this.runtimeId) {
      throw new WorkerControllerError('EXTERNAL_SENDER_DENIED', 'Untrusted external sender rejected');
    }
    const senderOrigin = this.#resolveSenderOrigin(sender);
    if (!senderOrigin || !sender.tab || typeof sender.tab.id !== 'number' || typeof sender.frameId !== 'number') {
      throw new WorkerControllerError(
        'INVALID_SENDER_METADATA',
        'Sender origin, tab.id, and frameId are required from browser'
      );
    }

    if (!rawPayload || typeof rawPayload !== 'object' || Array.isArray(rawPayload)) {
      throw new WorkerControllerError('INVALID_PAYLOAD', 'Payload must be an object');
    }
    const serializedBytes = Buffer.byteLength(JSON.stringify(rawPayload), 'utf8');
    if (serializedBytes > MAX_LOGICAL_MESSAGE_BYTES) {
      throw new WorkerControllerError('PAYLOAD_TOO_LARGE', 'Content payload exceeds 256 KiB W1/P7 limit');
    }
    if (
      rawPayload.kind !== 'USER_EXPLICIT_PAGE_SELECTION' ||
      rawPayload.explicitUserGesture !== true ||
      typeof rawPayload.selectionText !== 'string' ||
      rawPayload.selectionText.trim().length === 0
    ) {
      throw new WorkerControllerError('INVALID_PAYLOAD', 'Explicit user page selection required');
    }

    // Explicitly discard any spoofed origin/tabId/approved/execute/approvalRef fields in rawPayload.
    this.selectionCounter += 1;
    const selectionId = `sel-${this.selectionCounter}`;
    const entry = {
      selectionId,
      origin: senderOrigin,
      url: sender.url ?? senderOrigin,
      tabId: sender.tab.id,
      frameId: sender.frameId,
      documentId: sender.documentId ?? null,
      selectionText: rawPayload.selectionText,
      pageTitle: typeof rawPayload.pageTitle === 'string' ? rawPayload.pageTitle : '',
      capturedAt: Number.isFinite(rawPayload.capturedAt) ? Math.trunc(rawPayload.capturedAt) : Date.now(),
      stale: false,
      staleReason: null,
      confirmedForTransfer: false,
    };
    this.selections.set(selectionId, entry);
    return { ...entry };
  }

  handleTabUpdated(tabId, changeInfo = {}) {
    const navigated = Boolean(changeInfo.url) || changeInfo.status === 'loading' || Boolean(changeInfo.documentId);
    if (!navigated) return;
    for (const sel of this.selections.values()) {
      if (sel.tabId !== tabId) continue;
      if (changeInfo.url && changeInfo.url !== sel.url) {
        sel.stale = true;
        sel.staleReason = 'TAB_NAVIGATED_URL_CHANGED';
        sel.confirmedForTransfer = false;
      } else if (changeInfo.documentId && sel.documentId && changeInfo.documentId !== sel.documentId) {
        sel.stale = true;
        sel.staleReason = 'DOCUMENT_REPLACED';
        sel.confirmedForTransfer = false;
      } else if (changeInfo.status === 'loading') {
        sel.stale = true;
        sel.staleReason = 'TAB_RELOADING';
        sel.confirmedForTransfer = false;
      }
    }
  }

  handleTabRemoved(tabId) {
    for (const sel of this.selections.values()) {
      if (sel.tabId === tabId) {
        sel.stale = true;
        sel.staleReason = 'TAB_CLOSED';
        sel.confirmedForTransfer = false;
      }
    }
  }

  handlePermissionsRemoved(origins = []) {
    const revokedSet = new Set(origins);
    for (const sel of this.selections.values()) {
      const originPrefix = `${sel.origin}/`;
      if (revokedSet.has(sel.origin) || revokedSet.has(originPrefix) || revokedSet.has('<all_urls>')) {
        sel.stale = true;
        sel.staleReason = 'PERMISSION_REVOKED';
        sel.confirmedForTransfer = false;
      }
    }
  }

  confirmSelectionInSidePanel(selectionId) {
    const sel = this.selections.get(selectionId);
    if (!sel) {
      throw new WorkerControllerError('SELECTION_NOT_FOUND', 'Unknown selection');
    }
    if (sel.stale) {
      throw new WorkerControllerError(
        'SELECTION_STALE_RESELECT_REQUIRED',
        `Selection is stale (${sel.staleReason}); explicit user re-selection required`
      );
    }
    sel.confirmedForTransfer = true;
    return { ...sel };
  }

  sendStatefulViaSendNativeMessage() {
    throw new WorkerControllerError(
      'SEND_NATIVE_MESSAGE_FORBIDDEN_FOR_STATEFUL_SESSION',
      'chrome.runtime.sendNativeMessage spawns one-shot processes and cannot carry stateful or streaming sessions'
    );
  }

  async #openPortAndAuthenticate() {
    if (this.keyVault) {
      await this.keyVault.loadKeys(this.clientID);
    }
    if (typeof this.connectNative !== 'function') {
      throw new WorkerControllerError('NATIVE_MESSAGING_UNAVAILABLE', 'chrome.runtime.connectNative unavailable');
    }

    const port = await this.connectNative(NATIVE_HOST_NAME);
    this.port = port;
    const responseQueue = [];
    let waitingResolve = null;

    port.onMessage.addListener((msg) => {
      if (waitingResolve) {
        const resolve = waitingResolve;
        waitingResolve = null;
        resolve(msg);
      } else {
        responseQueue.push(msg);
      }
    });

    port.onDisconnect.addListener(() => {
      this.handlePortDisconnect();
    });

    this.#nextPortMessage = () => {
      if (responseQueue.length > 0) {
        return Promise.resolve(responseQueue.shift());
      }
      return new Promise((resolve) => {
        waitingResolve = resolve;
      });
    };

    const prologueHash = computeNoisePrologueHash({
      protocolMajor: this.protocolMajor,
      coreID: this.coreID,
      clientID: this.clientID,
      enrollmentGeneration: this.enrollmentGeneration,
      clientRole: this.clientRole,
    });
    const handshake = new NoiseIKInitiatorHandshake({
      localStaticPrivRaw: this.localNoiseStaticPrivRaw,
      remoteStaticPubRaw: this.coreNoiseStaticPubRaw,
      prologueHash,
      ephemeralKeypair: this.ephemeralFactory ? this.ephemeralFactory() : null,
    });

    const msg1 = handshake.writeMessage1();
    port.postMessage({
      op: 'noise_handshake_msg1',
      clientID: this.clientID,
      protocolMajor: this.protocolMajor,
      msg1Base64: msg1.toString('base64'),
    });

    const msg2Envelope = await this.#nextPortMessage();
    if (!msg2Envelope || !msg2Envelope.ok || msg2Envelope.op !== 'noise_handshake_msg2') {
      this.handlePortDisconnect();
      throw new WorkerControllerError(
        'HANDSHAKE_FAILED',
        msg2Envelope?.error ?? 'Core rejected Noise IK handshake'
      );
    }

    this.noiseSession = handshake.readMessage2(Buffer.from(msg2Envelope.msg2Base64, 'base64'));
    this.connected = true;
  }

  #nextPortMessage = null;

  async connectAndHandshake() {
    if (this.connected && this.noiseSession && !this.noiseSession.closed) {
      return { connected: true, clientID: this.clientID };
    }
    await this.#openPortAndAuthenticate();
    return { connected: true, clientID: this.clientID };
  }

  handlePortDisconnect() {
    if (this.noiseSession) {
      this.noiseSession.close();
    }
    this.noiseSession = null;
    this.connected = false;
    this.port = null;
    this.#nextPortMessage = null;
  }

  async sendEncryptedCommand(commandObj) {
    if (!this.connected || !this.port || !this.noiseSession || this.noiseSession.closed) {
      throw new WorkerControllerError('NOT_CONNECTED', 'Native Noise channel is not connected');
    }
    const payload = Buffer.from(JSON.stringify(commandObj), 'utf8');
    if (payload.length > MAX_LOGICAL_MESSAGE_BYTES) {
      throw new WorkerControllerError('PAYLOAD_TOO_LARGE', 'Encrypted command exceeds 256 KiB W1/P7 limit');
    }
    const frames = this.noiseSession.sendMessage(payload, { padTo4KiB: true });
    let lastEnvelope = null;
    for (const frame of frames) {
      this.port.postMessage({
        op: 'noise_frame',
        frameBase64: frame.toString('base64'),
      });
      lastEnvelope = await this.#nextPortMessage();
      if (!lastEnvelope || !lastEnvelope.ok) {
        throw new WorkerControllerError('CORE_ERROR', lastEnvelope?.error ?? 'Native Host rejected frame');
      }
    }
    if (!lastEnvelope || lastEnvelope.op !== 'noise_reply_frames') {
      throw new WorkerControllerError('PROTOCOL_ERROR', 'Missing noise_reply_frames from Core');
    }
    let assembled = null;
    for (const b64 of lastEnvelope.framesBase64) {
      const part = this.noiseSession.receiveFrame(Buffer.from(b64, 'base64'), {
        require4KiBPadding: true,
      });
      if (part !== null) {
        assembled = part;
      }
    }
    if (!assembled) {
      throw new WorkerControllerError('PROTOCOL_ERROR', 'Incomplete encrypted reply from Core');
    }
    return JSON.parse(assembled.toString('utf8'));
  }

  async submitProposalToCore(selectionId, { workspaceID, requestId = crypto.randomUUID(), operation = 'proposeAction' }) {
    const sel = this.selections.get(selectionId);
    if (!sel) {
      throw new WorkerControllerError('SELECTION_NOT_FOUND', 'Unknown selection');
    }
    if (sel.stale) {
      throw new WorkerControllerError(
        'SELECTION_STALE_RESELECT_REQUIRED',
        `Cannot submit stale selection (${sel.staleReason})`
      );
    }
    if (!sel.confirmedForTransfer) {
      throw new WorkerControllerError(
        'TRANSFER_CONFIRMATION_REQUIRED',
        'Local selection must be explicitly confirmed in Side Panel before Core transmission'
      );
    }

    return this.sendEncryptedCommand({
      operation,
      workspaceID,
      requestId,
      selection: {
        selectionId: sel.selectionId,
        origin: sel.origin,
        tabId: sel.tabId,
        frameId: sel.frameId,
        documentId: sel.documentId,
        pageTitle: sel.pageTitle,
        capturedAt: sel.capturedAt,
        selectionText: sel.selectionText,
      },
    });
  }

  async recoverAfterWorkerRestart() {
    // Discard stale in-memory connection/auth state; mark existing selections stale conservatively.
    this.handlePortDisconnect();
    for (const sel of this.selections.values()) {
      if (!sel.stale) {
        sel.stale = true;
        sel.staleReason = 'WORKER_RESTART_REVERIFY_REQUIRED';
        sel.confirmedForTransfer = false;
      }
    }

    await this.connectAndHandshake();

    // Perform strictly read-only inspectState + cursor sync; NEVER auto-start runs or reuse approvals.
    const snapshot = await this.sendEncryptedCommand({
      operation: 'inspectState',
      requestId: `recover-${crypto.randomUUID()}`,
      cursor: this.lastCursor,
    });
    if (typeof snapshot.nextCursor === 'number') {
      this.lastCursor = snapshot.nextCursor;
    }
    return {
      reauthenticated: true,
      readOnlySyncOnly: true,
      autoStartedRunsCount: this.autoStartedRunsCount,
      snapshot,
    };
  }
}
