"""Structural draft schema tests; not a substitute for product wire tests."""
import json
from pathlib import Path
import unittest

from jsonschema import Draft202012Validator
from generate_number_cases import generate_cases

ROOT = Path(__file__).resolve().parents[1]


def schema(name):
    document = json.loads((ROOT / f"{name}-v1.schema.json").read_text())
    Draft202012Validator.check_schema(document)
    return Draft202012Validator(document)


class SchemaTests(unittest.TestCase):
    def test_numeric_fixture_matches_independent_oracle(self):
        path = ROOT.parent / "Tests/OchesCoreTests/Fixtures/envelopes/numeric-cases.json"
        self.assertEqual(json.loads(path.read_text()), generate_cases())

    def test_shared_request_cases(self):
        validator = schema("request")
        path = ROOT.parent / "Tests/OchesCoreTests/Fixtures/envelopes/request-cases.json"
        for case in json.loads(path.read_text()):
            with self.subTest(case=case["name"]):
                self.assertEqual(validator.is_valid(case["request"]), case["valid"])

    def test_request(self):
        validator = schema("request")
        request = {"protocolMajor": 1, "protocolMinor": 0, "clientId": "c", "workspaceId": "w", "requestId": "r", "operation": "q", "payload": {}}
        self.assertTrue(validator.is_valid(request))
        for value in [None, "00", "1\n", "-1"]:
            revised = {**request, "expectedRevision": {"objectId": "o", "storeGeneration": "g", "revision": value}}
            self.assertFalse(validator.is_valid(revised), repr(value))
        self.assertFalse(validator.is_valid({**request, "payload": None}))
        self.assertFalse(validator.is_valid({**request, "unexpected": True}))

    def test_shared_response_cases(self):
        validator = schema("response")
        path = ROOT.parent / "Tests/OchesCoreTests/Fixtures/envelopes/response-cases.json"
        for case in json.loads(path.read_text()):
            with self.subTest(case=case["name"]):
                self.assertEqual(validator.is_valid(case["response"]), case["valid"])

    def test_response_exclusive_result(self):
        validator = schema("response")
        self.assertTrue(validator.is_valid({"requestId": "r", "result": {"ok": {}}}))
        error = {"code": "UNAVAILABLE", "message": "unavailable", "action": "retry later"}
        self.assertTrue(validator.is_valid({"requestId": "r", "result": {"error": error}}))
        self.assertFalse(validator.is_valid({"requestId": "r", "result": {"ok": {}, "error": error}}))
        self.assertFalse(validator.is_valid({"requestId": "r", "result": {}}))
        revision = {"objectId": "o", "storeGeneration": "g", "revision": "42"}
        self.assertTrue(validator.is_valid({"requestId": "r", "result": {"ok": {}}, "revision": revision}))
        self.assertFalse(validator.is_valid({"requestId": "r", "result": {"ok": {}}, "revision": {**revision, "storeGeneration": ""}}))
        self.assertFalse(validator.is_valid({"requestId": "r", "result": {"ok": {}}, "revision": None}))

    def test_shared_event_cases(self):
        validator = schema("event")
        path = ROOT.parent / "Tests/OchesCoreTests/Fixtures/envelopes/event-cases.json"
        for case in json.loads(path.read_text()):
            with self.subTest(case=case["name"]):
                self.assertEqual(validator.is_valid(case["event"]), case["valid"])

    def test_event_sequence(self):
        validator = schema("event")
        event = {"eventId": "e", "sourceId": "s", "sequence": "0", "kind": "example", "payload": {}}
        self.assertTrue(validator.is_valid(event))
        for sequence in ["01", "1\n", "-1", 1, None]:
            self.assertFalse(validator.is_valid({**event, "sequence": sequence}), repr(sequence))


if __name__ == "__main__":
    unittest.main()
