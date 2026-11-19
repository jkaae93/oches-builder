import crypto from 'node:crypto';
import fs from 'node:fs';
import assert from 'node:assert/strict';

export const PROTOCOL_NAME = Buffer.from('Noise_IK_25519_ChaChaPoly_SHA256', 'utf8');
const PKCS8_X25519_PREFIX = Buffer.from('302e020100300506032b656e04220420', 'hex');
const SPKI_X25519_PREFIX = Buffer.from('302a300506032b656e032100', 'hex');

export function x25519PublicFromPrivate(privRaw) {
  const privKey = crypto.createPrivateKey({
    key: Buffer.concat([PKCS8_X25519_PREFIX, privRaw]),
    format: 'der',
    type: 'pkcs8',
  });
  const spki = crypto.createPublicKey(privKey).export({ format: 'der', type: 'spki' });
  return spki.subarray(SPKI_X25519_PREFIX.length);
}

export function x25519DH(privRaw, pubRaw) {
  const privKey = crypto.createPrivateKey({
    key: Buffer.concat([PKCS8_X25519_PREFIX, privRaw]),
    format: 'der',
    type: 'pkcs8',
  });
  const pubKey = crypto.createPublicKey({
    key: Buffer.concat([SPKI_X25519_PREFIX, pubRaw]),
    format: 'der',
    type: 'spki',
  });
  return crypto.diffieHellman({ privateKey: privKey, publicKey: pubKey });
}

export function sha256(data) {
  return crypto.createHash('sha256').update(data).digest();
}

export function hmacSha256(key, data) {
  return crypto.createHmac('sha256', key).update(data).digest();
}

export function hkdfTwo(ck, ikm) {
  const temp = hmacSha256(ck, ikm);
  const out1 = hmacSha256(temp, Buffer.from([0x01]));
  const out2 = hmacSha256(temp, Buffer.concat([out1, Buffer.from([0x02])]));
  return [out1, out2];
}

export function makeNoiseNonce(n) {
  const buf = Buffer.alloc(12);
  buf.writeBigUInt64LE(BigInt(n), 4);
  return buf;
}

export class CipherState {
  constructor(key = null) {
    this.key = key;
    this.nonce = 0n;
  }

  initializeKey(key) {
    this.key = key;
    this.nonce = 0n;
  }

  encrypt(ad, pt) {
    if (!this.key) return pt;
    const iv = makeNoiseNonce(this.nonce);
    this.nonce += 1n;
    const cipher = crypto.createCipheriv('chacha20-poly1305', this.key, iv, { authTagLength: 16 });
    if (ad.length > 0) cipher.setAAD(ad);
    const ct = cipher.update(pt);
    const final = cipher.final();
    const tag = cipher.getAuthTag();
    return Buffer.concat([ct, final, tag]);
  }

  decrypt(ad, data) {
    if (!this.key) return data;
    if (data.length < 16) throw new Error('decryptionFailed');
    const iv = makeNoiseNonce(this.nonce);
    this.nonce += 1n;
    const ct = data.subarray(0, data.length - 16);
    const tag = data.subarray(data.length - 16);
    const decipher = crypto.createDecipheriv('chacha20-poly1305', this.key, iv, { authTagLength: 16 });
    if (ad.length > 0) decipher.setAAD(ad);
    decipher.setAuthTag(tag);
    return Buffer.concat([decipher.update(ct), decipher.final()]);
  }
}

export class SymmetricState {
  constructor() {
    this.h = Buffer.from(PROTOCOL_NAME);
    this.ck = Buffer.from(PROTOCOL_NAME);
    this.cipher = new CipherState(null);
  }

  mixHash(data) {
    this.h = sha256(Buffer.concat([this.h, data]));
  }

  mixKey(ikm) {
    const [nextCK, tempK] = hkdfTwo(this.ck, ikm);
    this.ck = nextCK;
    this.cipher.initializeKey(tempK);
  }

  encryptAndHash(pt) {
    const ct = this.cipher.encrypt(this.h, pt);
    this.mixHash(ct);
    return ct;
  }

  decryptAndHash(ct) {
    const pt = this.cipher.decrypt(this.h, ct);
    this.mixHash(ct);
    return pt;
  }

  split() {
    const [k1, k2] = hkdfTwo(this.ck, Buffer.alloc(0));
    return [new CipherState(k1), new CipherState(k2), k1, k2];
  }
}

export function buildChunkPlaintext(logicalMessageId, chunkIndex, isFinal, body, padTo4KiB = true) {
  const header = Buffer.alloc(21);
  header.writeBigUInt64BE(BigInt(logicalMessageId), 0);
  header.writeUInt32BE(chunkIndex, 8);
  header.writeUInt8(isFinal ? 1 : 0, 12);
  header.writeUInt32BE(body.length, 13);
  const unpadded = 21 + body.length;
  const paddingLen = padTo4KiB ? Math.max(1, Math.ceil(unpadded / 4096)) * 4096 - unpadded : 0;
  header.writeUInt32BE(paddingLen, 17);
  return Buffer.concat([header, body, Buffer.alloc(paddingLen, 0)]);
}

export function runDeterministicExchange(input) {
  const iStaticPriv = Buffer.from(input.initiatorStaticPrivHex, 'hex');
  const iStaticPub = x25519PublicFromPrivate(iStaticPriv);
  const iEphemPriv = Buffer.from(input.initiatorEphemPrivHex, 'hex');
  const iEphemPub = x25519PublicFromPrivate(iEphemPriv);

  const rStaticPriv = Buffer.from(input.responderStaticPrivHex, 'hex');
  const rStaticPub = x25519PublicFromPrivate(rStaticPriv);
  const rEphemPriv = Buffer.from(input.responderEphemPrivHex, 'hex');
  const rEphemPub = x25519PublicFromPrivate(rEphemPriv);

  const prologue = Buffer.from(input.prologueHashHex, 'hex');

  // Initiator write msg1
  const initSym = new SymmetricState();
  initSym.mixHash(prologue);
  initSym.mixHash(rStaticPub);
  initSym.mixHash(iEphemPub);
  initSym.mixKey(x25519DH(iEphemPriv, rStaticPub));
  const encS = initSym.encryptAndHash(iStaticPub);
  initSym.mixKey(x25519DH(iStaticPriv, rStaticPub));
  const encEmpty1 = initSym.encryptAndHash(Buffer.alloc(0));
  const msg1 = Buffer.concat([iEphemPub, encS, encEmpty1]);

  // Responder read msg1 + write msg2
  const respSym = new SymmetricState();
  respSym.mixHash(prologue);
  respSym.mixHash(rStaticPub);
  if (msg1.length !== 96) throw new Error('zeroRTTForbidden');
  const rePub = msg1.subarray(0, 32);
  respSym.mixHash(rePub);
  respSym.mixKey(x25519DH(rStaticPriv, rePub));
  const decS = respSym.decryptAndHash(msg1.subarray(32, 80));
  if (!decS.equals(iStaticPub)) throw new Error('staticKeyMismatch');
  respSym.mixKey(x25519DH(rStaticPriv, decS));
  const decPayload1 = respSym.decryptAndHash(msg1.subarray(80));
  if (decPayload1.length !== 0) throw new Error('zeroRTTForbidden');

  respSym.mixHash(rEphemPub);
  respSym.mixKey(x25519DH(rEphemPriv, rePub));
  respSym.mixKey(x25519DH(rEphemPriv, decS));
  const encEmpty2 = respSym.encryptAndHash(Buffer.alloc(0));
  const msg2 = Buffer.concat([rEphemPub, encEmpty2]);

  // Initiator read msg2
  if (msg2.length !== 48) throw new Error('zeroRTTForbidden');
  initSym.mixHash(msg2.subarray(0, 32));
  initSym.mixKey(x25519DH(iEphemPriv, msg2.subarray(0, 32)));
  initSym.mixKey(x25519DH(iStaticPriv, msg2.subarray(0, 32)));
  const decPayload2 = initSym.decryptAndHash(msg2.subarray(32));
  if (decPayload2.length !== 0) throw new Error('zeroRTTForbidden');

  assert.equal(initSym.h.toString('hex'), respSym.h.toString('hex'));

  const [iSend, iRecv, kI2R, kR2I] = initSym.split();
  const [rRecv, rSend] = respSym.split();

  const body = Buffer.from(input.plaintextHex, 'hex');
  const chunkPT = buildChunkPlaintext(1, 0, true, body, true);
  const frame0 = iSend.encrypt(Buffer.alloc(0), chunkPT);
  const decFrame0 = rRecv.decrypt(Buffer.alloc(0), frame0);

  let externalDecryptedHex = '';
  if (input.externalFrameHex) {
    const extFrame = Buffer.from(input.externalFrameHex, 'hex');
    const extCipher = new CipherState(kI2R);
    const extPT = extCipher.decrypt(Buffer.alloc(0), extFrame);
    const extLen = extPT.readUInt32BE(13);
    externalDecryptedHex = extPT.subarray(21, 21 + extLen).toString('hex');
  }

  return {
    msg1Hex: msg1.toString('hex'),
    msg2Hex: msg2.toString('hex'),
    handshakeHashHex: initSym.h.toString('hex'),
    kI2RHex: kI2R.toString('hex'),
    kR2IHex: kR2I.toString('hex'),
    frame0Hex: frame0.toString('hex'),
    decryptedHex: decFrame0.subarray(21, 21 + decFrame0.readUInt32BE(13)).toString('hex'),
    externalDecryptedHex,
  };
}

if (process.argv[1]?.endsWith('noise_ik_reference.mjs') && process.argv.includes('--self-test')) {
  const out = runDeterministicExchange({
    initiatorStaticPrivHex: '11'.repeat(32),
    initiatorEphemPrivHex: '22'.repeat(32),
    responderStaticPrivHex: '33'.repeat(32),
    responderEphemPrivHex: '44'.repeat(32),
    prologueHashHex: 'aa'.repeat(32),
    plaintextHex: Buffer.from('hello-noise-ik').toString('hex'),
  });
  assert.equal(out.msg1Hex.length, 96 * 2);
  assert.equal(out.msg2Hex.length, 48 * 2);
  assert.equal(Buffer.from(out.decryptedHex, 'hex').toString('utf8'), 'hello-noise-ik');

  // Negative check: tampered AEAD tag fails
  const badFrame = Buffer.from(out.frame0Hex, 'hex');
  badFrame[badFrame.length - 1] ^= 0xff;
  assert.throws(() => {
    const c = new CipherState(Buffer.from(out.kI2RHex, 'hex'));
    c.decrypt(Buffer.alloc(0), badFrame);
  });
  console.log('noise_ik_reference self-test passed');
} else if (process.argv[1]?.endsWith('noise_ik_reference.mjs') && process.argv.includes('--stdin-json')) {
  const input = JSON.parse(fs.readFileSync(0, 'utf8'));
  const output = runDeterministicExchange(input);
  process.stdout.write(JSON.stringify(output));
}
