"""Offline design-contract experiment; NOT a product parser or security boundary."""
import json
from pathlib import Path
from jsonschema import Draft202012Validator

SCHEMA = json.loads((Path(__file__).parent / 'agent-definition-v1-prototype.schema.json').read_text())
Draft202012Validator.check_schema(SCHEMA)
VALIDATOR = Draft202012Validator(SCHEMA)


def reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('duplicate key: ' + key)
        result[key] = value
    return result


def decode(data):
    if len(data) > 262144:  # S3: definition document max 256 KiB
        raise ValueError('input too large')
    def reject_constant(value):
        raise ValueError('non-finite JSON number: ' + value)
    return json.loads(data.decode('utf-8'), object_pairs_hook=reject_duplicate_keys, parse_constant=reject_constant)


def check(instance):
    errors = [f'{list(e.absolute_path)}: {e.message}' for e in VALIDATOR.iter_errors(instance)]
    if errors:
        return errors
    for direction in ('inputs', 'outputs'):
        ids = [p['portId'] for p in instance[direction]]
        if len(ids) != len(set(ids)):
            errors.append(f'{direction}: duplicate portId')
    return errors
