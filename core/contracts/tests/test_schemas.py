"""Structural draft schema tests; not a substitute for product wire tests."""
import json
from pathlib import Path
import unittest

from jsonschema import Draft202012Validator

ROOT = Path(__file__).resolve().parents[1]


def schema(name):
    document = json.loads((ROOT / f"{name}-v1.schema.json").read_text())
    Draft202012Validator.check_schema(document)
    return Draft202012Validator(document)


class SchemaTests(unittest.TestCase):
    def test_request(self):
        validator = schema("request")
        request = {"protocolMajor": 1, "protocolMinor": 0, "clientId": "c", "workspaceId": "w", "requestId": "r", "operation": "q", "payload": {}}
        self.assertTrue(validator.is_valid(request))
        for value in [None, "00", "1\n", "-1"]:
            revised = {**request, "expectedRevision": {"objectId": "o", "storeGeneration": "g", "revision": value}}
            self.assertFalse(validator.is_valid(revised), repr(value))
        self.assertFalse(validator.is_valid({**request, "payload": None}))
        self.assertFalse(validator.is_valid({**request, "unexpected": True}))

    def test_response_exclusive_result(self):
        validator = schema("response")
        self.assertTrue(validator.is_valid({"requestId": "r", "result": {"ok": {}}}))
        error = {"code": "UNAVAILABLE", "message": "unavailable", "action": "retry later"}
        self.assertTrue(validator.is_valid({"requestId": "r", "result": {"error": error}}))
        self.assertFalse(validator.is_valid({"requestId": "r", "result": {"ok": {}, "error": error}}))
        self.assertFalse(validator.is_valid({"requestId": "r", "result": {}}))

    def test_event_sequence(self):
        validator = schema("event")
        event = {"eventId": "e", "sourceId": "s", "sequence": "0", "kind": "example", "payload": {}}
        self.assertTrue(validator.is_valid(event))
        for sequence in ["01", "1\n", "-1", 1, None]:
            self.assertFalse(validator.is_valid({**event, "sequence": sequence}), repr(sequence))


if __name__ == "__main__":
    unittest.main()
