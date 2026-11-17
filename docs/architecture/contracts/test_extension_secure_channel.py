"""Contract state-machine tests for EXTENSION_SECURE_CHANNEL.md and ADR-017.

This tests logical binding, 0-RTT blocking, chunking, 4 KiB padding, revocation,
key-storage fail-closed rules, and per-request Desktop approval boundaries.
It is NOT a production Noise_IK_25519_ChaChaPoly_SHA256 cryptographic library.
"""
import hashlib
import hmac
import json
import math
from typing import Optional, Tuple
import unittest
import rfc8785


SUITE = "Noise_IK_25519_ChaChaPoly_SHA256"
MAX_CHUNK_PLAINTEXT = 60 * 1024
PADDING_BUCKET = 4096
PRIVILEGED_OPS = {"workspace:write", "run:request", "context:transfer"}


def jcs_sha256(obj) -> str:
    return hashlib.sha256(rfc8785.dumps(obj)).hexdigest()


def sign_mac(secret_key: bytes, payload: dict) -> str:
    return hmac.new(secret_key, rfc8785.dumps(payload), hashlib.sha256).hexdigest()


def verify_mac(secret_key: bytes, payload: dict, sig: str) -> bool:
    expected = sign_mac(secret_key, payload)
    return hmac.compare_digest(expected, sig)


def pad_to_bucket(body: bytes, bucket: int = PADDING_BUCKET) -> Tuple[bytes, int]:
    total = max(bucket, math.ceil((len(body) + 4) / bucket) * bucket)
    pad_len = total - len(body)
    return body + (b"\x00" * pad_len), pad_len


class KeyStore:
    def __init__(self, backend_secure: bool = True):
        self.backend_secure = backend_secure
        self.keys: dict[str, bytes] = {}

    def store(self, key_id: str, material: bytes) -> None:
        if not self.backend_secure:
            raise RuntimeError("KEY_UNAVAILABLE")
        self.keys[key_id] = material

    def load(self, key_id: str) -> bytes:
        if not self.backend_secure or key_id not in self.keys:
            raise RuntimeError("KEY_UNAVAILABLE")
        return self.keys[key_id]


class CoreAuthority:
    def __init__(self):
        self.core_id = "core-macos-1"
        self.core_signing_id = "core-sig-1"
        self.core_signing_secret = b"core-signing-secret"
        self.core_noise_pub = "core-x25519-pub-1"
        self.registered_client_keys: dict[str, bytes] = {}
        self.enrollments: dict[str, dict] = {}
        self.approvals: dict[str, dict] = {}

    def enroll(self, transcript: dict, client_pop: str, desktop_confirmed: bool) -> dict:
        if not desktop_confirmed:
            raise PermissionError("DENIED")
        digest = jcs_sha256(transcript)
        client_sig_secret = self.registered_client_keys.get(transcript["clientSigningKeyId"])
        if not client_sig_secret or not verify_mac(
            client_sig_secret, {"transcriptDigest": digest, "nonce": transcript["nonce"]}, client_pop
        ):
            raise PermissionError("DENIED")
        client_id = transcript["clientId"]
        record = {
            "clientId": client_id,
            "trustLevel": "USER_ENROLLED_KEY",
            "signingKeyId": transcript["clientSigningKeyId"],
            "noiseStaticPub": transcript["clientNoiseStaticPub"],
            "workspaceId": transcript["workspaceId"],
            "permissions": set(transcript["permissions"]),
            "generation": transcript["enrollmentGeneration"],
            "revoked": False,
        }
        self.enrollments[client_id] = record
        receipt_body = {
            "coreId": self.core_id,
            "clientId": client_id,
            "transcriptDigest": digest,
            "coreNoiseStaticPub": self.core_noise_pub,
            "clientNoiseStaticPub": transcript["clientNoiseStaticPub"],
            "generation": transcript["enrollmentGeneration"],
            "result": "ENROLLED",
        }
        return {"body": receipt_body, "sig": sign_mac(self.core_signing_secret, receipt_body)}

    def revoke(self, client_id: str) -> None:
        if client_id in self.enrollments:
            self.enrollments[client_id]["revoked"] = True

    def issue_desktop_approval(self, approval_id: str, workspace_id: str, op: str, input_digest: str) -> None:
        self.approvals[approval_id] = {
            "workspaceId": workspace_id,
            "operation": op,
            "inputDigest": input_digest,
            "consumed": False,
        }


class CoreNoiseSession:
    def __init__(self, core: CoreAuthority, client_id: str, prologue: list, client_noise_pub: str):
        self.core = core
        self.client_id = client_id
        self.rec = core.enrollments.get(client_id)
        self.state = "INIT"
        self.authorized = False
        self.closed = False
        self.session_key = b""
        self.next_chunk = {}
        self.buffers = {}
        self._handshake(prologue, client_noise_pub)

    def _handshake(self, prologue: list, client_noise_pub: str) -> None:
        if not self.rec or self.rec["revoked"]:
            self.closed = True
            raise PermissionError("DENIED")
        expected_prologue = [
            1,
            SUITE,
            self.core.core_id,
            self.client_id,
            self.rec["generation"],
            "chrome_extension",
        ]
        if prologue != expected_prologue or client_noise_pub != self.rec["noiseStaticPub"]:
            self.closed = True
            raise PermissionError("DENIED")
        self.session_key = hashlib.sha256(
            rfc8785.dumps({"p": prologue, "c": client_noise_pub, "s": self.core.core_noise_pub})
        ).digest()
        self.state = "SPLIT"

    def authorize_hello(self, major: int) -> None:
        if self.closed or self.state != "SPLIT" or major != 1:
            self.closed = True
            raise PermissionError("DENIED")
        if self.rec["revoked"]:
            self.closed = True
            raise PermissionError("DENIED")
        self.authorized = True

    def seal_chunk(self, msg_id: str, chunk_idx: int, is_final: bool, data: bytes, pad_len: int = 0) -> dict:
        frame = {
            "msgId": msg_id,
            "chunkIndex": chunk_idx,
            "isFinal": is_final,
            "dataHex": data.hex(),
            "padLen": pad_len,
        }
        tag = sign_mac(self.session_key, frame)
        return {"frame": frame, "tag": tag}

    def receive_chunk(self, sealed: dict) -> Optional[dict]:
        if self.closed or self.state != "SPLIT" or not self.authorized:
            self.closed = True
            raise PermissionError("ZERO_RTT_OR_UNAUTHORIZED_REJECTED")
        if self.rec["revoked"]:
            self.closed = True
            raise PermissionError("DENIED")
        frame = sealed["frame"]
        if not verify_mac(self.session_key, frame, sealed["tag"]):
            self.closed = True
            raise PermissionError("AEAD_TAMPER_REJECTED")
        msg_id = frame["msgId"]
        expected_idx = self.next_chunk.get(msg_id, 0)
        if frame["chunkIndex"] != expected_idx:
            self.closed = True
            raise ValueError("CHUNK_ORDER_MISMATCH")
        chunk_bytes = bytes.fromhex(frame["dataHex"])
        if len(chunk_bytes) > MAX_CHUNK_PLAINTEXT:
            self.closed = True
            raise ValueError("INVALID_INPUT")
        self.next_chunk[msg_id] = expected_idx + 1
        self.buffers.setdefault(msg_id, bytearray()).extend(chunk_bytes)
        if not frame["isFinal"]:
            return None
        raw = bytes(self.buffers.pop(msg_id))
        pad_len = frame["padLen"]
        if pad_len > len(raw):
            self.closed = True
            raise ValueError("INVALID_PADDING")
        body = raw[: len(raw) - pad_len] if pad_len else raw
        return self._dispatch(json.loads(body.decode("utf-8")))

    def close(self) -> None:
        if self.buffers:
            self.buffers.clear()
            self.closed = True
            raise ValueError("INCOMPLETE_STREAM")
        self.closed = True

    def _dispatch(self, req: dict) -> dict:
        op = req["operation"]
        ws = req["workspaceId"]
        if ws != self.rec["workspaceId"] or op not in self.rec["permissions"]:
            return {"error": "DENIED"}
        if op in PRIVILEGED_OPS:
            approval_id = req.get("approvalRef")
            if not approval_id or approval_id not in self.core.approvals:
                return {"error": "APPROVAL_REQUIRED"}
            app = self.core.approvals[approval_id]
            if (
                app["consumed"]
                or app["workspaceId"] != ws
                or app["operation"] != op
                or app["inputDigest"] != jcs_sha256(req["payload"])
            ):
                return {"error": "DENIED"}
            app["consumed"] = True
        response_bytes = rfc8785.dumps({"ok": True, "trustLevel": self.rec["trustLevel"], "op": op})
        padded, pad_len = pad_to_bucket(response_bytes)
        return {"paddedBody": padded, "padLen": pad_len}


class ExtensionSecureChannelContractTests(unittest.TestCase):
    def setUp(self):
        self.core = CoreAuthority()
        self.client_sig_secret = b"client-sig-secret-1"
        self.core.registered_client_keys["client-sig-1"] = self.client_sig_secret
        self.client_noise_pub = "client-x25519-pub-1"
        self.transcript = {
            "version": 1,
            "coreId": self.core.core_id,
            "coreSigningKeyId": self.core.core_signing_id,
            "coreNoiseStaticPub": self.core.core_noise_pub,
            "clientId": "chrome-ext-1",
            "clientSigningKeyId": "client-sig-1",
            "clientNoiseStaticPub": self.client_noise_pub,
            "workspaceId": "ws-1",
            "permissions": ["workspace:read", "workspace:write"],
            "enrollmentGeneration": 1,
            "nonce": "enroll-nonce-1",
        }
        self.pop = sign_mac(
            self.client_sig_secret,
            {"transcriptDigest": jcs_sha256(self.transcript), "nonce": "enroll-nonce-1"},
        )

    def _enroll_and_open(self) -> CoreNoiseSession:
        receipt = self.core.enroll(self.transcript, self.pop, desktop_confirmed=True)
        self.assertTrue(verify_mac(self.core.core_signing_secret, receipt["body"], receipt["sig"]))
        self.assertEqual("USER_ENROLLED_KEY", self.core.enrollments["chrome-ext-1"]["trustLevel"])
        prologue = [1, SUITE, self.core.core_id, "chrome-ext-1", 1, "chrome_extension"]
        session = CoreNoiseSession(self.core, "chrome-ext-1", prologue, self.client_noise_pub)
        session.authorize_hello(1)
        return session

    def test_enrollment_binds_keys_and_enforces_4kib_bucket_padding(self):
        session = self._enroll_and_open()
        req = json.dumps({"operation": "workspace:read", "workspaceId": "ws-1", "payload": {}}).encode("utf-8")
        c0 = session.seal_chunk("m1", 0, False, req[:20])
        c1 = session.seal_chunk("m1", 1, True, req[20:])
        self.assertIsNone(session.receive_chunk(c0))
        res = session.receive_chunk(c1)
        self.assertIsNotNone(res)
        self.assertEqual(0, len(res["paddedBody"]) % PADDING_BUCKET)

    def test_rejects_zero_rtt_before_hello_authorization(self):
        self.core.enroll(self.transcript, self.pop, desktop_confirmed=True)
        prologue = [1, SUITE, self.core.core_id, "chrome-ext-1", 1, "chrome_extension"]
        session = CoreNoiseSession(self.core, "chrome-ext-1", prologue, self.client_noise_pub)
        # Do NOT call authorize_hello
        req = json.dumps({"operation": "workspace:read", "workspaceId": "ws-1", "payload": {}}).encode("utf-8")
        with self.assertRaises(PermissionError):
            session.receive_chunk(session.seal_chunk("m0", 0, True, req))
        self.assertTrue(session.closed)

    def test_rejects_mismatched_static_key_and_prologue_tamper(self):
        self.core.enroll(self.transcript, self.pop, desktop_confirmed=True)
        good_prologue = [1, SUITE, self.core.core_id, "chrome-ext-1", 1, "chrome_extension"]
        with self.assertRaises(PermissionError):
            CoreNoiseSession(self.core, "chrome-ext-1", good_prologue, "attacker-x25519-pub")
        tampered_prologue = [1, SUITE, self.core.core_id, "chrome-ext-1", 99, "chrome_extension"]
        with self.assertRaises(PermissionError):
            CoreNoiseSession(self.core, "chrome-ext-1", tampered_prologue, self.client_noise_pub)

    def test_rejects_chunk_reorder_tamper_and_incomplete_stream(self):
        session = self._enroll_and_open()
        req = json.dumps({"operation": "workspace:read", "workspaceId": "ws-1", "payload": {}}).encode("utf-8")
        c0 = session.seal_chunk("m1", 0, False, req[:15])
        c1 = session.seal_chunk("m1", 1, True, req[15:])
        with self.assertRaises(ValueError):
            session.receive_chunk(c1)  # chunk 1 before chunk 0

        session2 = self._enroll_and_open()
        bad = session2.seal_chunk("m2", 0, True, req)
        bad["tag"] = "0" * 64
        with self.assertRaises(PermissionError):
            session2.receive_chunk(bad)

        session3 = self._enroll_and_open()
        session3.receive_chunk(session3.seal_chunk("m3", 0, False, req[:10]))
        with self.assertRaises(ValueError):
            session3.close()  # missing isFinal=True

    def test_revoked_key_and_insecure_keystore_fail_closed(self):
        session = self._enroll_and_open()
        self.core.revoke("chrome-ext-1")
        req = json.dumps({"operation": "workspace:read", "workspaceId": "ws-1", "payload": {}}).encode("utf-8")
        with self.assertRaises(PermissionError):
            session.receive_chunk(session.seal_chunk("m1", 0, True, req))

        insecure_store = KeyStore(backend_secure=False)
        with self.assertRaises(RuntimeError) as ctx:
            insecure_store.store("client-sig-1", b"secret")
        self.assertEqual("KEY_UNAVAILABLE", str(ctx.exception))

    def test_privileged_write_requires_bound_desktop_approval(self):
        session = self._enroll_and_open()
        payload = {"file": "README.md", "action": "edit"}
        # Missing approval -> APPROVAL_REQUIRED
        req_no_app = json.dumps({"operation": "workspace:write", "workspaceId": "ws-1", "payload": payload}).encode("utf-8")
        res1 = session.receive_chunk(session.seal_chunk("w1", 0, True, req_no_app))
        self.assertEqual({"error": "APPROVAL_REQUIRED"}, res1)

        # Issue Desktop approval for payload
        self.core.issue_desktop_approval("app-1", "ws-1", "workspace:write", jcs_sha256(payload))

        # Tampered target under same approvalRef -> DENIED
        tampered = json.dumps(
            {"operation": "workspace:write", "workspaceId": "ws-1", "payload": {"file": ".env", "action": "edit"}, "approvalRef": "app-1"}
        ).encode("utf-8")
        res2 = session.receive_chunk(session.seal_chunk("w2", 0, True, tampered))
        self.assertEqual({"error": "DENIED"}, res2)

        # Valid matching payload + approval -> succeeds once; replay -> DENIED
        valid = json.dumps(
            {"operation": "workspace:write", "workspaceId": "ws-1", "payload": payload, "approvalRef": "app-1"}
        ).encode("utf-8")
        res3 = session.receive_chunk(session.seal_chunk("w3", 0, True, valid))
        self.assertEqual(0, len(res3["paddedBody"]) % PADDING_BUCKET)

        res4 = session.receive_chunk(session.seal_chunk("w4", 0, True, valid))
        self.assertEqual({"error": "DENIED"}, res4)

        # Cross-workspace query leaks nothing other than uniform DENIED
        other_ws = json.dumps({"operation": "workspace:read", "workspaceId": "ws-secret", "payload": {}}).encode("utf-8")
        self.assertEqual({"error": "DENIED"}, session.receive_chunk(session.seal_chunk("r-ws", 0, True, other_ws)))


if __name__ == "__main__":
    unittest.main()
