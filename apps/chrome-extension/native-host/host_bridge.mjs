import {
  MAX_LOGICAL_MESSAGE_BYTES,
  NoiseIKResponderHandshake,
  computeNoisePrologueHash,
} from '../../../core/contracts/noise_ik_client.mjs';

export const CHROME_ORIGIN_REGEX = /^chrome-extension:\/\/[a-p]{32}\/$/;
export const HOST_NAME_REGEX = /^[a-z0-9]+(\.[a-z0-9_]+)+$/;
export const MAX_NATIVE_FRAME_BYTES = MAX_LOGICAL_MESSAGE_BYTES; // 256 KiB (W1/P7)

const ALLOWED_MANIFEST_KEYS = new Set(['name', 'description', 'path', 'type', 'allowed_origins']);
const ALLOWED_ENVELOPE_OPS = new Set([
  'ping',
  'bootstrap',
  'noise_handshake_msg1',
  'noise_frame',
]);

export function validateNativeManifest(manifest) {
  if (!manifest || typeof manifest !== 'object' || Array.isArray(manifest)) {
    throw new Error('INVALID_MANIFEST: root must be object');
  }
  for (const key of Object.keys(manifest)) {
    if (!ALLOWED_MANIFEST_KEYS.has(key)) {
      throw new Error(`UNKNOWN_FIELD: ${key}`);
    }
  }
  if (typeof manifest.name !== 'string' || !HOST_NAME_REGEX.test(manifest.name)) {
    throw new Error('INVALID_MANIFEST: bad host name');
  }
  if (typeof manifest.description !== 'string' || manifest.description.trim().length === 0) {
    throw new Error('INVALID_MANIFEST: empty description');
  }
  if (
    typeof manifest.path !== 'string' ||
    !manifest.path.startsWith('/') ||
    manifest.path.includes('..')
  ) {
    throw new Error('INVALID_MANIFEST: bad executable path');
  }
  if (manifest.type !== 'stdio') {
    throw new Error('INVALID_MANIFEST: type must be stdio');
  }
  if (!Array.isArray(manifest.allowed_origins) || manifest.allowed_origins.length === 0) {
    throw new Error('INVALID_MANIFEST: allowed_origins required');
  }
  const seen = new Set();
  for (const origin of manifest.allowed_origins) {
    if (typeof origin !== 'string' || !CHROME_ORIGIN_REGEX.test(origin)) {
      throw new Error(`INVALID_MANIFEST: invalid origin ${origin}`);
    }
    if (seen.has(origin)) {
      throw new Error(`INVALID_MANIFEST: duplicate origin ${origin}`);
    }
    seen.add(origin);
  }
  return manifest;
}

export function encodeNativeFrame(payloadObjOrBuffer) {
  const body = Buffer.isBuffer(payloadObjOrBuffer)
    ? payloadObjOrBuffer
    : Buffer.from(JSON.stringify(payloadObjOrBuffer), 'utf8');
  if (body.length === 0 || body.length > MAX_NATIVE_FRAME_BYTES) {
    throw new Error(`FRAME_SIZE_EXCEEDED: ${body.length}`);
  }
  const header = Buffer.alloc(4);
  header.writeUInt32LE(body.length, 0);
  return Buffer.concat([header, body]);
}

export class NativeFrameDecoder {
  constructor() {
    this.buffer = Buffer.alloc(0);
  }

  push(chunk) {
    this.buffer = Buffer.concat([this.buffer, Buffer.from(chunk)]);
    const frames = [];
    while (this.buffer.length >= 4) {
      const length = this.buffer.readUInt32LE(0);
      if (length === 0 || length > MAX_NATIVE_FRAME_BYTES) {
        this.buffer = Buffer.alloc(0);
        throw new Error(`FRAME_SIZE_EXCEEDED: ${length}`);
      }
      if (this.buffer.length < 4 + length) {
        break;
      }
      const rawBody = this.buffer.subarray(4, 4 + length);
      this.buffer = this.buffer.subarray(4 + length);
      let parsed;
      try {
        parsed = JSON.parse(rawBody.toString('utf8'));
      } catch {
        throw new Error('INVALID_UTF8_JSON');
      }
      if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
        throw new Error('INVALID_UTF8_JSON');
      }
      frames.push(parsed);
    }
    return frames;
  }
}

export class NativeHostBridge {
  constructor({ manifest, coreBridge = null, coreNoiseStaticPrivRaw = null }) {
    this.manifest = validateNativeManifest(manifest);
    this.allowedOrigins = new Set(this.manifest.allowed_origins);
    this.coreBridge = coreBridge;
    this.coreNoiseStaticPrivRaw = coreNoiseStaticPrivRaw;
    this.activeOrigin = null;
    this.noiseSession = null;
    this.decoder = new NativeFrameDecoder();
  }

  open(argv) {
    if (!Array.isArray(argv) || argv.length < 2) {
      throw new Error('MISSING_CALLER_ORIGIN');
    }
    const callerOrigin = argv[1];
    if (typeof callerOrigin !== 'string' || !CHROME_ORIGIN_REGEX.test(callerOrigin)) {
      throw new Error(`ORIGIN_NOT_ALLOWED: ${callerOrigin}`);
    }
    if (!this.allowedOrigins.has(callerOrigin)) {
      throw new Error(`ORIGIN_NOT_ALLOWED: ${callerOrigin}`);
    }
    this.activeOrigin = callerOrigin;
    this.noiseSession = null;
    return {
      origin: callerOrigin,
      // Chrome argv[1] cannot distinguish standalone direct execution; remains USER_ENROLLED_KEY.
      trustLevel: 'USER_ENROLLED_KEY',
      directExecutionUnproven: true,
    };
  }

  close() {
    if (this.noiseSession) {
      this.noiseSession.close();
    }
    this.noiseSession = null;
    this.activeOrigin = null;
    this.decoder = new NativeFrameDecoder();
  }

  handleChunk(chunk) {
    if (!this.activeOrigin) {
      throw new Error('PORT_CLOSED');
    }
    const messages = this.decoder.push(chunk);
    const responses = [];
    for (const msg of messages) {
      if (msg.callerOrigin !== undefined && msg.callerOrigin !== this.activeOrigin) {
        throw new Error('ORIGIN_MISMATCH');
      }
      if (typeof msg.op !== 'string' || !ALLOWED_ENVELOPE_OPS.has(msg.op)) {
        throw new Error(`UNSUPPORTED_ENVELOPE_OP: ${msg.op}`);
      }
      if (msg.op === 'ping') {
        responses.push({ ok: true, op: 'pong', callerOrigin: this.activeOrigin, trustLevel: 'USER_ENROLLED_KEY' });
        continue;
      }
      if (msg.op === 'bootstrap') {
        if (!this.coreBridge?.getBootstrap) {
          throw new Error('CORE_UNAVAILABLE');
        }
        responses.push({ ok: true, op: 'bootstrap', data: this.coreBridge.getBootstrap() });
        continue;
      }
      if (msg.op === 'noise_handshake_msg1') {
        if (!this.coreNoiseStaticPrivRaw || !this.coreBridge?.lookupEnrolledClient) {
          throw new Error('CORE_UNAVAILABLE');
        }
        const record = this.coreBridge.lookupEnrolledClient(msg.clientID);
        if (!record || record.revoked) {
          throw new Error('CLIENT_REVOKED_OR_UNKNOWN');
        }
        const prologueHash = computeNoisePrologueHash({
          protocolMajor: msg.protocolMajor,
          coreID: record.coreID,
          clientID: record.clientID,
          enrollmentGeneration: record.enrollmentGeneration,
          clientRole: record.clientRole,
        });
        const responder = new NoiseIKResponderHandshake({
          localStaticPrivRaw: this.coreNoiseStaticPrivRaw,
          prologueHash,
        });
        const msg1Buf = Buffer.from(msg.msg1Base64, 'base64');
        responder.readMessage1(msg1Buf, (rsPub) => {
          if (rsPub.toString('base64') !== record.noiseStaticPublicKeyBase64) {
            throw new Error('STATIC_KEY_MISMATCH');
          }
        });
        const { message: msg2, session } = responder.writeMessage2();
        this.noiseSession = session;
        responses.push({ ok: true, op: 'noise_handshake_msg2', msg2Base64: msg2.toString('base64') });
        continue;
      }
      if (msg.op === 'noise_frame') {
        if (!this.noiseSession || !this.coreBridge?.handleDecryptedCommand) {
          throw new Error('HANDSHAKE_INCOMPLETE');
        }
        const frameBuf = Buffer.from(msg.frameBase64, 'base64');
        const plaintextBuf = this.noiseSession.receiveFrame(frameBuf, { require4KiBPadding: true });
        if (plaintextBuf === null) {
          responses.push({ ok: true, op: 'noise_chunk_ack' });
          continue;
        }
        const command = JSON.parse(plaintextBuf.toString('utf8'));
        const replyObj = this.coreBridge.handleDecryptedCommand(command, {
          chromeArgvOrigin: this.activeOrigin,
          trustLevel: 'USER_ENROLLED_KEY',
        });
        const replyFrames = this.noiseSession.sendMessage(Buffer.from(JSON.stringify(replyObj), 'utf8'), {
          padTo4KiB: true,
        });
        responses.push({
          ok: true,
          op: 'noise_reply_frames',
          framesBase64: replyFrames.map((f) => f.toString('base64')),
        });
      }
    }
    return responses;
  }
}

export function attachStdioBridge(bridge, stdin = process.stdin, stdout = process.stdout, argv = process.argv) {
  bridge.open(argv);
  stdin.on('data', (chunk) => {
    try {
      const replies = bridge.handleChunk(chunk);
      for (const reply of replies) {
        stdout.write(encodeNativeFrame(reply));
      }
    } catch (err) {
      stdout.write(encodeNativeFrame({ ok: false, error: err.message }));
      bridge.close();
      stdin.destroy();
    }
  });
  stdin.on('end', () => {
    bridge.close();
  });
}
