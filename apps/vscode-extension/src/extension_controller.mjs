import crypto from 'node:crypto';
import {
  NoiseIKInitiatorHandshake,
  computeNoisePrologueHash,
} from '../../../core/contracts/noise_ik_client.mjs';
import { assertOperationAllowed, evaluateVSCodeEnvironment } from './environment_guard.mjs';
import { VSCODE_PUBLISHER_ID } from './secret_vault.mjs';
import { buildWebviewHtml, validateWebviewMessage } from './webview_bridge.mjs';

export class VSCodeControllerError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

export class VSCodeExtensionController {
  constructor({
    clientID,
    coreID,
    coreNoiseStaticPubRaw,
    enrollmentGeneration = 1,
    protocolMajor = 1,
    protocolMinorRange = [0, 0],
    publisherExtensionId = VSCODE_PUBLISHER_ID,
    secretVault,
    coreTransport,
    ephemeralFactory = null,
    initialEnvironment = {},
  }) {
    this.clientID = clientID;
    this.coreID = coreID;
    this.coreNoiseStaticPubRaw = Buffer.from(coreNoiseStaticPubRaw);
    this.enrollmentGeneration = enrollmentGeneration;
    this.protocolMajor = protocolMajor;
    this.protocolMinorRange = protocolMinorRange;
    this.publisherExtensionId = publisherExtensionId;
    this.secretVault = secretVault;
    this.coreTransport = coreTransport;
    this.ephemeralFactory = ephemeralFactory;

    this.environment = evaluateVSCodeEnvironment(initialEnvironment);
    this.trustGeneration = 1;
    this.negotiatedMinor = null;
    this.noiseSession = null;
    this.connected = false;
    this.lastCursor = 0;
    this.autoStartedRunsCount = 0;
    this.latestSnapshot = null;
  }

  refreshEnvironment(nextEnvironment) {
    this.environment = evaluateVSCodeEnvironment(nextEnvironment);
    this.trustGeneration += 1;
    return this.environment;
  }

  onWorkspaceTrustChanged(isTrusted) {
    this.environment = evaluateVSCodeEnvironment({
      ...this.environment,
      isTrusted,
      workspaceFolders: this.environment.workspaceUris.map((raw) => ({
        scheme: raw.includes('://') ? raw.split('://')[0] : 'file',
        raw,
      })),
    });
    this.trustGeneration += 1;
    return this.environment;
  }

  onWorkspaceFoldersChanged(workspaceFolders, isTrusted) {
    this.environment = evaluateVSCodeEnvironment({
      remoteName: this.environment.remoteName ?? '',
      uiKind: this.environment.uiKind,
      workspaceFolders,
      isTrusted,
    });
    this.trustGeneration += 1;
    return this.environment;
  }

  async connectAndNegotiate() {
    if (this.environment.status === 'UNSUPPORTED') {
      throw new VSCodeControllerError(
        'REMOTE_UNSUPPORTED',
        'Cannot connect to Core from an unsupported remote/virtual/web VS Code host'
      );
    }

    const keys = await this.secretVault.loadKeys(this.clientID);
    const caps = await this.coreTransport.negotiateVersion({
      protocolMajor: this.protocolMajor,
      minMinor: this.protocolMinorRange[0],
      maxMinor: this.protocolMinorRange[1],
      publisherExtensionId: this.publisherExtensionId,
    });

    if (
      !caps ||
      caps.protocolMajor !== this.protocolMajor ||
      typeof caps.selectedMinor !== 'number' ||
      caps.selectedMinor < this.protocolMinorRange[0] ||
      caps.selectedMinor > this.protocolMinorRange[1]
    ) {
      throw new VSCodeControllerError('VERSION_UNSUPPORTED', 'Incompatible Core protocol version');
    }
    this.negotiatedMinor = caps.selectedMinor;

    const prologueHash = computeNoisePrologueHash({
      protocolMajor: this.protocolMajor,
      coreID: this.coreID,
      clientID: this.clientID,
      enrollmentGeneration: this.enrollmentGeneration,
      clientRole: 'vscode-extension',
    });

    const handshake = new NoiseIKInitiatorHandshake({
      localStaticPrivRaw: keys.noiseStaticPrivateRaw,
      remoteStaticPubRaw: this.coreNoiseStaticPubRaw,
      prologueHash,
      ephemeralKeypair: this.ephemeralFactory ? this.ephemeralFactory() : null,
    });
    const msg1 = handshake.writeMessage1();
    const msg2 = await this.coreTransport.exchangeHandshake({
      clientID: this.clientID,
      protocolMajor: this.protocolMajor,
      msg1Base64: msg1.toString('base64'),
    });
    this.noiseSession = handshake.readMessage2(Buffer.from(msg2.msg2Base64, 'base64'));
    this.connected = true;
    return {
      connected: true,
      negotiatedMinor: this.negotiatedMinor,
      // Explicitly record publisher.name attribution without upgrading to PLATFORM_BOUND.
      trustLevel: 'USER_ENROLLED_KEY',
      publisherExtensionId: this.publisherExtensionId,
    };
  }

  disconnect() {
    if (this.noiseSession) {
      this.noiseSession.close();
    }
    this.noiseSession = null;
    this.connected = false;
  }

  async #sendEncryptedCoreCommand(payloadObj) {
    if (!this.connected || !this.noiseSession || this.noiseSession.closed) {
      throw new VSCodeControllerError('NOT_CONNECTED', 'Noise channel is not connected');
    }
    const frames = this.noiseSession.sendMessage(Buffer.from(JSON.stringify(payloadObj), 'utf8'), {
      padTo4KiB: true,
    });
    const replyFrames = await this.coreTransport.sendEncryptedFrames(
      frames.map((f) => f.toString('base64'))
    );
    let assembled = null;
    for (const b64 of replyFrames) {
      const part = this.noiseSession.receiveFrame(Buffer.from(b64, 'base64'), {
        require4KiBPadding: true,
      });
      if (part !== null) assembled = part;
    }
    if (!assembled) {
      throw new VSCodeControllerError('PROTOCOL_ERROR', 'Incomplete encrypted Core reply');
    }
    return JSON.parse(assembled.toString('utf8'));
  }

  async executeCommand(
    operation,
    {
      workspaceID = null,
      expectedRevision = null,
      requestId = crypto.randomUUID(),
      approvalRef = null,
      payload = {},
    } = {}
  ) {
    // Re-check trust and host boundary BEFORE any connection or Core call even on direct command execution.
    assertOperationAllowed(this.environment, operation);

    return this.#sendEncryptedCoreCommand({
      protocolMajor: this.protocolMajor,
      protocolMinor: this.negotiatedMinor ?? 0,
      publisherExtensionId: this.publisherExtensionId,
      trustGeneration: this.trustGeneration,
      workspaceID,
      requestId,
      expectedRevision,
      approvalRef,
      operation,
      payload,
    });
  }

  async pollCursorOrRecoverSnapshot() {
    const resp = await this.executeCommand('inspectSnapshot', {
      payload: { cursor: this.lastCursor },
    });
    if (resp.error === 'CURSOR_EXPIRED') {
      const fullSnapshot = await this.executeCommand('inspectSnapshot', {
        payload: { fullSnapshot: true },
      });
      this.latestSnapshot = fullSnapshot;
      if (typeof fullSnapshot.nextCursor === 'number') {
        this.lastCursor = fullSnapshot.nextCursor;
      }
      return {
        recoveredFromCursorExpiry: true,
        autoStartedRunsCount: this.autoStartedRunsCount,
        snapshot: fullSnapshot,
      };
    }
    this.latestSnapshot = resp;
    if (typeof resp.nextCursor === 'number') {
      this.lastCursor = resp.nextCursor;
    }
    return {
      recoveredFromCursorExpiry: false,
      autoStartedRunsCount: this.autoStartedRunsCount,
      snapshot: resp,
    };
  }

  renderWebview({ nonce, cspSource, projectSnippet = '' }) {
    return buildWebviewHtml({
      nonce,
      cspSource,
      viewState: {
        statusText: `${this.environment.status}${this.environment.reason ? ` (${this.environment.reason})` : ''}`,
        workspaceText: this.environment.workspaceUris.join(', ') || 'None',
        projectSnippet,
        allowWorkspaceOperations: this.environment.allowWorkspaceOperations,
      },
    });
  }

  async handleWebviewMessage(rawMessage, { expectedWebviewId, expectedRevision = null, workspaceID = null }) {
    const valid = validateWebviewMessage(rawMessage, { expectedWebviewId });
    const opMap = {
      requestStatus: 'getStatus',
      proposeAnalyze: 'analyzeWorkspace',
      proposeApply: 'applyPlan',
      requestCancel: 'inspectSnapshot',
    };
    const coreOp = opMap[valid.op];
    return this.executeCommand(coreOp, {
      workspaceID: workspaceID ?? valid.workspaceId,
      expectedRevision,
      payload: { planId: valid.planId, targetUri: valid.targetUri },
    });
  }
}
