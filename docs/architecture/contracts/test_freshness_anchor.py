"""Contract model tests for RECOVERY_FRESHNESS_ANCHOR.md and SQLITE_STORAGE_RECOVERY_CONTRACT.md.

Tests Two-Tier FreshnessAnchor compare-and-advance semantics, RFC 8785 JCS signed
DurableIntent verification, single-step crash recovery, and fail-closed transition to
RECOVERY_QUARANTINED on rollback, fork, unsigned DB rows, gap > 1, revoked key, or
missing anchor.
"""
import hashlib
import hmac
from pathlib import Path
import sqlite3
import tempfile
import unittest
import rfc8785


def jcs_sha256(obj) -> str:
    return hashlib.sha256(rfc8785.dumps(obj)).hexdigest()


def sign_mac(secret: bytes, obj: dict) -> str:
    return hmac.new(secret, rfc8785.dumps(obj), hashlib.sha256).hexdigest()


def verify_mac(secret: bytes, obj: dict, sig: str) -> bool:
    return hmac.compare_digest(sign_mac(secret, obj), sig)


class FreshnessAnchor:
    def __init__(self, workspace_id: str, epoch: int = 1, available: bool = True):
        self.available = available
        self.state = {
            "workspaceId": workspace_id,
            "epoch": epoch,
            "sequence": 0,
            "headDigest": "GENESIS",
            "storeGeneration": "gen-1",
        }

    def read(self) -> dict:
        if not self.available:
            raise RuntimeError("UNAVAILABLE")
        return dict(self.state)

    def advance(self, expected: dict, next_state: dict) -> dict:
        if not self.available:
            raise RuntimeError("UNAVAILABLE")
        cur = self.state
        if (
            cur["workspaceId"] != expected["workspaceId"]
            or cur["epoch"] != expected["epoch"]
            or cur["sequence"] != expected["sequence"]
            or cur["headDigest"] != expected["headDigest"]
        ):
            raise ValueError("CONFLICT")
        if (
            next_state["workspaceId"] != cur["workspaceId"]
            or next_state["epoch"] != cur["epoch"]
            or next_state["sequence"] != cur["sequence"] + 1
            or next_state["previousHeadDigest"] != cur["headDigest"]
        ):
            raise ValueError("CONFLICT")
        self.state = {
            "workspaceId": cur["workspaceId"],
            "epoch": cur["epoch"],
            "sequence": next_state["sequence"],
            "headDigest": next_state["headDigest"],
            "storeGeneration": next_state["storeGeneration"],
        }
        return dict(self.state)


class RecoveryCoordinator:
    def __init__(self, db_path: Path, anchor: FreshnessAnchor):
        self.db_path = db_path
        self.anchor = anchor
        self.intent_keys: dict[str, tuple[bytes, bool]] = {"ik-1": (b"intent-signing-secret-1", True)}
        self.desktop_chain_secret = b"desktop-ui-chain-secret"
        self.desktop_approvals: dict[str, dict] = {}
        self.ledger: list[dict] = []
        self.status = "ACTIVE"
        self._init_db()

    def _open_db(self) -> sqlite3.Connection:
        db = sqlite3.connect(str(self.db_path), timeout=5, isolation_level=None)
        db.execute("PRAGMA foreign_keys = ON")
        db.execute("PRAGMA synchronous = FULL")
        return db

    def _init_db(self) -> None:
        db = self._open_db()
        try:
            db.execute("PRAGMA journal_mode = WAL")
            db.executescript(
                """
                CREATE TABLE IF NOT EXISTS approvals(
                    approval_id TEXT PRIMARY KEY,
                    consumed INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS intents(
                    intent_id TEXT PRIMARY KEY,
                    sequence INTEGER NOT NULL,
                    previous_head_digest TEXT NOT NULL,
                    head_digest TEXT NOT NULL,
                    action TEXT NOT NULL,
                    target_digest TEXT NOT NULL,
                    approval_id TEXT NOT NULL,
                    status TEXT NOT NULL
                );
                """
            )
        finally:
            db.close()

    def issue_approval(self, approval_id: str, action: str, target_digest: str) -> None:
        payload = {"approvalId": approval_id, "action": action, "targetDigest": target_digest}
        self.desktop_approvals[approval_id] = {
            "payload": payload,
            "sig": sign_mac(self.desktop_chain_secret, payload),
        }
        db = self._open_db()
        try:
            db.execute("BEGIN IMMEDIATE")
            db.execute("INSERT INTO approvals(approval_id, consumed) VALUES (?, 0)", (approval_id,))
            db.commit()
        finally:
            db.close()

    def _verify_approval_chain(self, approval_id: str, action: str, target_digest: str) -> bool:
        entry = self.desktop_approvals.get(approval_id)
        if not entry:
            return False
        p = entry["payload"]
        if p["action"] != action or p["targetDigest"] != target_digest:
            return False
        return verify_mac(self.desktop_chain_secret, p, entry["sig"])

    def _last_ledger_head(self) -> tuple[int, str]:
        if not self.ledger:
            return 0, "GENESIS"
        last = self.ledger[-1]["intent"]
        return last["sequence"], self.ledger[-1]["headDigest"]

    def commit_intent_in_db(self, intent_id: str, approval_id: str, action: str, target_digest: str) -> dict:
        if self.status != "ACTIVE":
            raise PermissionError("RECOVERY_QUARANTINED")
        prev_seq, prev_head = self._last_ledger_head()
        intent_body = {
            "intentId": intent_id,
            "workspaceId": "ws-1",
            "epoch": 1,
            "sequence": prev_seq + 1,
            "previousHeadDigest": prev_head,
            "action": action,
            "targetDigest": target_digest,
            "approvalId": approval_id,
            "policyVersion": 1,
            "storeGeneration": "gen-1",
            "issuedAt": "2026-11-16T12:00:00Z",
        }
        head_digest = jcs_sha256(intent_body)
        db = self._open_db()
        try:
            db.execute("BEGIN IMMEDIATE")
            used = db.execute("UPDATE approvals SET consumed=1 WHERE approval_id=? AND consumed=0", (approval_id,)).rowcount
            if used != 1:
                db.rollback()
                raise PermissionError("APPROVAL_REQUIRED")
            db.execute(
                "INSERT INTO intents VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                (intent_id, prev_seq + 1, prev_head, head_digest, action, target_digest, approval_id, "INTENT_COMMITTED"),
            )
            db.commit()
        finally:
            db.close()
        return {"intent": intent_body, "headDigest": head_digest}

    def sign_and_append_ledger(self, prepared: dict, key_id: str = "ik-1") -> dict:
        secret, active = self.intent_keys[key_id]
        if not active:
            raise PermissionError("KEY_REVOKED")
        entry = {
            "intent": prepared["intent"],
            "headDigest": prepared["headDigest"],
            "keyId": key_id,
            "sig": sign_mac(secret, prepared["intent"]),
        }
        self.ledger.append(entry)
        return entry

    def advance_anchor_and_complete(self, entry: dict) -> dict:
        cur = self.anchor.read()
        intent = entry["intent"]
        nxt = {
            "workspaceId": intent["workspaceId"],
            "epoch": intent["epoch"],
            "sequence": intent["sequence"],
            "previousHeadDigest": intent["previousHeadDigest"],
            "headDigest": entry["headDigest"],
            "storeGeneration": intent["storeGeneration"],
        }
        res = self.anchor.advance(cur, nxt)
        db = self._open_db()
        try:
            db.execute("BEGIN IMMEDIATE")
            db.execute("UPDATE intents SET status='COMPLETE' WHERE intent_id=?", (intent["intentId"],))
            db.commit()
        finally:
            db.close()
        return res

    def _quarantine(self) -> str:
        self.status = "RECOVERY_QUARANTINED"
        return self.status

    def reconcile_on_restart(self) -> str:
        try:
            anchor_state = self.anchor.read()
        except RuntimeError:
            return self._quarantine()

        ledger_seq, ledger_head = self._last_ledger_head()

        # Check for unsigned DB intents committed before crash
        db = self._open_db()
        try:
            committed_rows = db.execute(
                "SELECT intent_id, sequence, action, target_digest, approval_id FROM intents WHERE status='INTENT_COMMITTED' ORDER BY sequence"
            ).fetchall()
        finally:
            db.close()

        for row in committed_rows:
            intent_id, seq, action, target_digest, approval_id = row
            in_ledger = any(e["intent"]["intentId"] == intent_id for e in self.ledger)
            if not in_ledger:
                # Never trust unsigned DB row alone; verify approval chain or fail closed
                if not self._verify_approval_chain(approval_id, action, target_digest):
                    return self._quarantine()
                # Even with approval chain, do not auto-sign unverified DB mutations into ledger without re-approval
                return self._quarantine()

        # Verify ledger integrity & signatures sequentially
        expected_prev = "GENESIS"
        for idx, entry in enumerate(self.ledger, start=1):
            intent = entry["intent"]
            if intent["sequence"] != idx or intent["previousHeadDigest"] != expected_prev:
                return self._quarantine()
            key_info = self.intent_keys.get(entry["keyId"])
            if not key_info:
                return self._quarantine()
            secret, active = key_info
            if not active or not verify_mac(secret, intent, entry["sig"]):
                return self._quarantine()
            if jcs_sha256(intent) != entry["headDigest"]:
                return self._quarantine()
            expected_prev = entry["headDigest"]

        a_seq = anchor_state["sequence"]
        a_head = anchor_state["headDigest"]

        if a_seq > ledger_seq:
            # Rollback detected: DB/ledger is older than anchor
            return self._quarantine()

        if a_seq == ledger_seq:
            if a_head != ledger_head:
                return self._quarantine()
            self.status = "ACTIVE"
            return "ACTIVE"

        # ledger_seq > a_seq
        if ledger_seq - a_seq > 1:
            return self._quarantine()

        # Single-step idempotent retry: ledger.sequence == anchor.sequence + 1
        pending = self.ledger[-1]
        if pending["intent"]["previousHeadDigest"] != a_head:
            return self._quarantine()
        try:
            self.advance_anchor_and_complete(pending)
        except (ValueError, RuntimeError):
            return self._quarantine()
        self.status = "ACTIVE"
        return "RECOVERED_ACTIVE"


class FreshnessAnchorContractTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db_path = Path(self.tmp.name) / "core.db"
        self.anchor = FreshnessAnchor("ws-1")
        self.coord = RecoveryCoordinator(self.db_path, self.anchor)

    def tearDown(self):
        self.tmp.cleanup()

    def test_happy_path_and_cas_rejects_conflict(self):
        self.coord.issue_approval("app-1", "DELETE_ARTIFACT", "sha256:aaa")
        prepared = self.coord.commit_intent_in_db("int-1", "app-1", "DELETE_ARTIFACT", "sha256:aaa")
        entry = self.coord.sign_and_append_ledger(prepared)
        res = self.coord.advance_anchor_and_complete(entry)
        self.assertEqual(1, res["sequence"])
        self.assertEqual("ACTIVE", self.coord.reconcile_on_restart())

        # Direct stale CAS advance must fail with CONFLICT
        with self.assertRaises(ValueError):
            self.anchor.advance(
                {"workspaceId": "ws-1", "epoch": 1, "sequence": 0, "headDigest": "GENESIS"},
                {"workspaceId": "ws-1", "epoch": 1, "sequence": 1, "previousHeadDigest": "GENESIS", "headDigest": "fork", "storeGeneration": "gen-1"},
            )

    def test_single_step_crash_recovery_and_lost_response(self):
        self.coord.issue_approval("app-1", "DELETE_ARTIFACT", "sha256:bbb")
        prepared = self.coord.commit_intent_in_db("int-1", "app-1", "DELETE_ARTIFACT", "sha256:bbb")
        self.coord.sign_and_append_ledger(prepared)
        # Simulate crash before FreshnessAnchor.advance
        self.assertEqual("RECOVERED_ACTIVE", self.coord.reconcile_on_restart())
        self.assertEqual(1, self.anchor.read()["sequence"])

        # Simulate lost response after anchor actually advanced
        self.coord.issue_approval("app-2", "REVOKE_KEY", "sha256:ccc")
        prepared2 = self.coord.commit_intent_in_db("int-2", "app-2", "REVOKE_KEY", "sha256:ccc")
        entry2 = self.coord.sign_and_append_ledger(prepared2)
        self.coord.advance_anchor_and_complete(entry2)
        self.assertEqual("ACTIVE", self.coord.reconcile_on_restart())
        self.assertEqual(2, self.anchor.read()["sequence"])

    def test_unsigned_db_row_after_crash_enters_quarantine(self):
        self.coord.issue_approval("app-1", "DELETE_ARTIFACT", "sha256:ddd")
        self.coord.commit_intent_in_db("int-1", "app-1", "DELETE_ARTIFACT", "sha256:ddd")
        # Crash before signing / appending ledger
        self.assertEqual("RECOVERY_QUARANTINED", self.coord.reconcile_on_restart())
        with self.assertRaises(PermissionError):
            self.coord.commit_intent_in_db("int-2", "app-1", "DELETE_ARTIFACT", "sha256:eee")

    def test_rollback_and_fork_and_gap_enter_quarantine(self):
        # Advance to seq 2
        for i in (1, 2):
            self.coord.issue_approval(f"app-{i}", "DELETE_ARTIFACT", f"sha256:{i}")
            p = self.coord.commit_intent_in_db(f"int-{i}", f"app-{i}", "DELETE_ARTIFACT", f"sha256:{i}")
            e = self.coord.sign_and_append_ledger(p)
            self.coord.advance_anchor_and_complete(e)

        # Rollback ledger to seq 1 while anchor stays at seq 2
        self.coord.ledger.pop()
        self.assertEqual("RECOVERY_QUARANTINED", self.coord.reconcile_on_restart())

    def test_fork_at_same_sequence_quarantines(self):
        self.coord.issue_approval("app-1", "DELETE_ARTIFACT", "sha256:1")
        p = self.coord.commit_intent_in_db("int-1", "app-1", "DELETE_ARTIFACT", "sha256:1")
        e = self.coord.sign_and_append_ledger(p)
        self.coord.advance_anchor_and_complete(e)

        # Replace ledger[0] with a different valid-looking signed fork
        self.coord.ledger[0]["headDigest"] = "forked-digest"
        self.assertEqual("RECOVERY_QUARANTINED", self.coord.reconcile_on_restart())

    def test_gap_gt_1_revoked_key_and_missing_anchor_quarantine(self):
        self.coord.issue_approval("app-1", "DELETE_ARTIFACT", "sha256:1")
        p1 = self.coord.commit_intent_in_db("int-1", "app-1", "DELETE_ARTIFACT", "sha256:1")
        self.coord.sign_and_append_ledger(p1)
        self.coord.issue_approval("app-2", "DELETE_ARTIFACT", "sha256:2")
        p2 = self.coord.commit_intent_in_db("int-2", "app-2", "DELETE_ARTIFACT", "sha256:2")
        self.coord.sign_and_append_ledger(p2)
        # Anchor still at 0 while ledger at 2 -> gap > 1 -> quarantine
        self.assertEqual("RECOVERY_QUARANTINED", self.coord.reconcile_on_restart())

        # Missing anchor
        self.anchor.available = False
        self.assertEqual("RECOVERY_QUARANTINED", self.coord.reconcile_on_restart())

        # Revoked intent signing key
        self.anchor.available = True
        self.coord.ledger = [self.coord.ledger[0]]
        self.coord.intent_keys["ik-1"] = (b"intent-signing-secret-1", False)
        self.assertEqual("RECOVERY_QUARANTINED", self.coord.reconcile_on_restart())


if __name__ == "__main__":
    unittest.main()
