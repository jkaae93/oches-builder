import crypto from 'node:crypto';
import {
  PROTOCOL_NAME,
  SymmetricState,
  buildChunkPlaintext,
  sha256,
  x25519DH,
  x25519PublicFromPrivate,
} from './noise_ik_reference.mjs';

export const MAX_LOGICAL_MESSAGE_BYTES = 262_144;
export const CHUNK_HEADER_BYTES = 21;
export const MAX_CHUNK_PLAINTEXT_BYTES = 61_440;
export const MAX_CHUNK_BODY_BYTES = MAX_CHUNK_PLAINTEXT_BYTES - CHUNK_HEADER_BYTES;
export const PADDING_BUCKET_BYTES = 4_096;

export function canonicalizeJCS(value) {
  if (value === null || typeof value === 'boolean') {
    return JSON.stringify(value);
  }
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) {
      throw new Error('non-finite number cannot be serialized in JCS');
    }
    return Object.is(value, -0) ? '0' : JSON.stringify(value);
  }
  if (typeof value === 'string') {
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) {
    return `[${value.map((item) => canonicalizeJCS(item)).join(',')}]`;
  }
  if (typeof value === 'object') {
    const keys = Object.keys(value)
      .filter((k) => value[k] !== undefined)
      .sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
    const entries = keys.map((k) => `${JSON.stringify(k)}:${canonicalizeJCS(value[k])}`);
    return `{${entries.join(',')}}`;
  }
  throw new Error(`unsupported JCS type: ${typeof value}`);
}

export function canonicalSHA256(value) {
  return sha256(Buffer.from(canonicalizeJCS(value), 'utf8'));
}

export function computeNoisePrologueHash({
  protocolMajor,
  coreID,
  clientID,
  enrollmentGeneration,
  clientRole,
}) {
  if (!Number.isInteger(protocolMajor) || protocolMajor <= 0) {
    throw new Error('invalidPrologue: protocolMajor');
  }
  if (!coreID || !clientID || !clientRole) {
    throw new Error('invalidPrologue: missing string identifier');
  }
  if (!Number.isInteger(enrollmentGeneration) || enrollmentGeneration < 0) {
    throw new Error('invalidPrologue: enrollmentGeneration');
  }
  return canonicalSHA256([
    protocolMajor,
    PROTOCOL_NAME.toString('utf8'),
    coreID,
    clientID,
    enrollmentGeneration,
    clientRole,
  ]);
}

function generateRawX25519Keypair() {
  const { publicKey, privateKey } = crypto.generateKeyPairSync('x25519');
  const privDer = privateKey.export({ format: 'der', type: 'pkcs8' });
  const pubDer = publicKey.export({ format: 'der', type: 'spki' });
  return {
    privateRaw: privDer.subarray(privDer.length - 32),
    publicRaw: pubDer.subarray(pubDer.length - 32),
  };
}

class ChunkAccumulator {
  constructor() {
    this.activeMessageId = null;
    this.nextChunkIndex = 0;
    this.chunks = [];
    this.totalBytes = 0;
  }

  pushPlaintextFrame(frameBytes, { require4KiBPadding = true } = {}) {
    if (frameBytes.length < CHUNK_HEADER_BYTES) {
      throw new Error('invalidChunkHeader');
    }
    const msgId = frameBytes.readBigUInt64BE(0);
    const chunkIndex = frameBytes.readUInt32BE(8);
    const isFinal = frameBytes.readUInt8(12) === 1;
    const bodyLen = frameBytes.readUInt32BE(13);
    const paddingLen = frameBytes.readUInt32BE(17);

    if (require4KiBPadding && frameBytes.length % PADDING_BUCKET_BYTES !== 0) {
      throw new Error('invalidPadding');
    }
    if (CHUNK_HEADER_BYTES + bodyLen + paddingLen !== frameBytes.length) {
      throw new Error('invalidChunkHeader');
    }
    if (this.activeMessageId === null) {
      if (chunkIndex !== 0) throw new Error('chunkOrderMismatch');
      this.activeMessageId = msgId;
      this.nextChunkIndex = 0;
    } else if (msgId !== this.activeMessageId || chunkIndex !== this.nextChunkIndex) {
      throw new Error('chunkOrderMismatch');
    }

    if (this.totalBytes + bodyLen > MAX_LOGICAL_MESSAGE_BYTES) {
      throw new Error('messageTooLarge');
    }
    const body = frameBytes.subarray(CHUNK_HEADER_BYTES, CHUNK_HEADER_BYTES + bodyLen);
    const padding = frameBytes.subarray(CHUNK_HEADER_BYTES + bodyLen);
    for (const byte of padding) {
      if (byte !== 0) throw new Error('invalidPadding');
    }
    this.chunks.push(body);
    this.totalBytes += body.length;
    this.nextChunkIndex += 1;

    if (!isFinal) {
      return null;
    }
    const assembled = Buffer.concat(this.chunks);
    this.activeMessageId = null;
    this.nextChunkIndex = 0;
    this.chunks = [];
    this.totalBytes = 0;
    return assembled;
  }
}

export class NoiseTransportPeer {
  constructor(sendCipher, recvCipher, handshakeHash) {
    this.sendCipher = sendCipher;
    this.recvCipher = recvCipher;
    this.handshakeHash = handshakeHash;
    this.closed = false;
    this.logicalMessageSeq = 1;
    this.accumulator = new ChunkAccumulator();
  }

  sendMessage(payloadBytes, { padTo4KiB = true } = {}) {
    if (this.closed) throw new Error('channelClosed');
    const buf = Buffer.isBuffer(payloadBytes) ? payloadBytes : Buffer.from(payloadBytes);
    if (buf.length > MAX_LOGICAL_MESSAGE_BYTES) {
      throw new Error('messageTooLarge');
    }
    const msgId = this.logicalMessageSeq;
    this.logicalMessageSeq += 1;
    const frames = [];
    if (buf.length === 0) {
      const pt = buildChunkPlaintext(msgId, 0, true, buf, padTo4KiB);
      frames.push(this.sendCipher.encrypt(Buffer.alloc(0), pt));
      return frames;
    }
    let offset = 0;
    let chunkIndex = 0;
    while (offset < buf.length) {
      const end = Math.min(offset + MAX_CHUNK_BODY_BYTES, buf.length);
      const isFinal = end === buf.length;
      const slice = buf.subarray(offset, end);
      const pt = buildChunkPlaintext(msgId, chunkIndex, isFinal, slice, padTo4KiB);
      frames.push(this.sendCipher.encrypt(Buffer.alloc(0), pt));
      offset = end;
      chunkIndex += 1;
    }
    return frames;
  }

  receiveFrame(ciphertext, { require4KiBPadding = true } = {}) {
    if (this.closed) throw new Error('channelClosed');
    try {
      const frameBytes = this.recvCipher.decrypt(Buffer.alloc(0), Buffer.from(ciphertext));
      return this.accumulator.pushPlaintextFrame(frameBytes, { require4KiBPadding });
    } catch (err) {
      this.close();
      throw err;
    }
  }

  close() {
    this.closed = true;
  }
}

export class NoiseIKInitiatorHandshake {
  constructor({ localStaticPrivRaw, remoteStaticPubRaw, prologueHash, ephemeralKeypair = null }) {
    this.localStaticPrivRaw = Buffer.from(localStaticPrivRaw);
    this.localStaticPubRaw = x25519PublicFromPrivate(this.localStaticPrivRaw);
    this.remoteStaticPubRaw = Buffer.from(remoteStaticPubRaw);
    this.ephemeral = ephemeralKeypair ?? generateRawX25519Keypair();
    this.sym = new SymmetricState();
    this.sym.mixHash(Buffer.from(prologueHash));
    this.sym.mixHash(this.remoteStaticPubRaw);
    this.msg1Sent = false;
  }

  writeMessage1(zeroRTTPayload = Buffer.alloc(0)) {
    if (zeroRTTPayload && zeroRTTPayload.length > 0) {
      throw new Error('zeroRTTForbidden');
    }
    if (this.msg1Sent) throw new Error('handshakeIncomplete');
    this.msg1Sent = true;
    this.sym.mixHash(this.ephemeral.publicRaw);
    this.sym.mixKey(x25519DH(this.ephemeral.privateRaw, this.remoteStaticPubRaw));
    const encS = this.sym.encryptAndHash(this.localStaticPubRaw);
    this.sym.mixKey(x25519DH(this.localStaticPrivRaw, this.remoteStaticPubRaw));
    const encEmpty = this.sym.encryptAndHash(Buffer.alloc(0));
    return Buffer.concat([this.ephemeral.publicRaw, encS, encEmpty]);
  }

  readMessage2(message2) {
    if (!this.msg1Sent) throw new Error('handshakeIncomplete');
    const msg2 = Buffer.from(message2);
    if (msg2.length !== 48) {
      throw new Error('zeroRTTForbidden');
    }
    const rePub = msg2.subarray(0, 32);
    this.sym.mixHash(rePub);
    this.sym.mixKey(x25519DH(this.ephemeral.privateRaw, rePub));
    this.sym.mixKey(x25519DH(this.localStaticPrivRaw, rePub));
    const pt = this.sym.decryptAndHash(msg2.subarray(32));
    if (pt.length !== 0) {
      throw new Error('zeroRTTForbidden');
    }
    const [sendCipher, recvCipher] = this.sym.split();
    return new NoiseTransportPeer(sendCipher, recvCipher, Buffer.from(this.sym.h));
  }
}

export class NoiseIKResponderHandshake {
  constructor({ localStaticPrivRaw, prologueHash, ephemeralKeypair = null }) {
    this.localStaticPrivRaw = Buffer.from(localStaticPrivRaw);
    this.localStaticPubRaw = x25519PublicFromPrivate(this.localStaticPrivRaw);
    this.ephemeral = ephemeralKeypair ?? generateRawX25519Keypair();
    this.sym = new SymmetricState();
    this.sym.mixHash(Buffer.from(prologueHash));
    this.sym.mixHash(this.localStaticPubRaw);
    this.remoteEphemPubRaw = null;
    this.remoteStaticPubRaw = null;
  }

  readMessage1(message1, validateRemoteStatic) {
    const msg1 = Buffer.from(message1);
    if (msg1.length !== 96) {
      throw new Error('zeroRTTForbidden');
    }
    const rePub = msg1.subarray(0, 32);
    this.sym.mixHash(rePub);
    this.sym.mixKey(x25519DH(this.localStaticPrivRaw, rePub));
    const rsPub = this.sym.decryptAndHash(msg1.subarray(32, 80));
    validateRemoteStatic(rsPub);
    this.sym.mixKey(x25519DH(this.localStaticPrivRaw, rsPub));
    const pt = this.sym.decryptAndHash(msg1.subarray(80));
    if (pt.length !== 0) {
      throw new Error('zeroRTTForbidden');
    }
    this.remoteEphemPubRaw = rePub;
    this.remoteStaticPubRaw = rsPub;
    return rsPub;
  }

  writeMessage2() {
    if (!this.remoteEphemPubRaw || !this.remoteStaticPubRaw) {
      throw new Error('handshakeIncomplete');
    }
    this.sym.mixHash(this.ephemeral.publicRaw);
    this.sym.mixKey(x25519DH(this.ephemeral.privateRaw, this.remoteEphemPubRaw));
    this.sym.mixKey(x25519DH(this.ephemeral.privateRaw, this.remoteStaticPubRaw));
    const encEmpty = this.sym.encryptAndHash(Buffer.alloc(0));
    const [recvCipher, sendCipher] = this.sym.split();
    const session = new NoiseTransportPeer(sendCipher, recvCipher, Buffer.from(this.sym.h));
    return {
      message: Buffer.concat([this.ephemeral.publicRaw, encEmpty]),
      session,
    };
  }
}
