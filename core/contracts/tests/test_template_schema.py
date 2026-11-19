"""Local structural schema checks; semantic and raw-wire checks remain separate."""
import copy
import json
from pathlib import Path
import unittest
from jsonschema import Draft202012Validator

ROOT = Path(__file__).resolve().parents[1]


class TemplateSchemaTests(unittest.TestCase):
    def test_shared_core_cases(self):
        document = json.loads((ROOT / 'template-exchange-v1.schema.json').read_text())
        validator = Draft202012Validator(document)
        cases = json.loads((ROOT.parent / 'Tests/OchesCoreTests/Fixtures/template-exchange/cases.json').read_text())
        for case in cases:
            with self.subTest(name=case['name']):
                self.assertEqual(validator.is_valid(json.loads(case['rawJSON'])), case['schemaValid'])

    def test_all_node_shapes_and_unknown_fields(self):
        document = json.loads((ROOT / 'template-exchange-v1.schema.json').read_text())
        Draft202012Validator.check_schema(document)
        validator = Draft202012Validator(document)
        reference = {'id': 'ref', 'revision': '1'}
        extras = {
            'agent': {'definition': {'schemaVersion': {'major': 1, 'minor': 0}, 'definitionId': 'definition',
                                    'revision': 1, 'role': 'review', 'instructions': 'inspect', 'inputs': [],
                                    'outputs': [], 'tools': [], 'permissions': [],
                                    'resourceLimits': {'maxDurationSeconds': 60, 'maxAttempts': 1}}},
            'task': {'goal': 'fixture', 'resourceLimits': {'maxDurationSeconds': 60, 'maxRetries': 3}},
            'tool': {'capability': 'file.read', 'permissions': []},
            'memory': {'memoryRef': reference, 'evidenceRefs': [reference]},
            'evaluation': {'criteriaRef': reference, 'evaluatorRef': reference},
            'approval': {'action': 'apply', 'scope': 'workspace', 'targetRef': reference, 'expiresAfterSeconds': 900},
        }
        for kind, extra in extras.items():
            node = {'id': 'node', 'kind': kind, 'label': 'fixture', 'inputs': [], 'outputs': [], 'requirements': [], **extra}
            if kind == 'agent':
                del node['inputs']
                del node['outputs']
            template = {'schemaVersion': {'major': 1, 'minor': 0},
                        'metadata': {'name': 'fixture', 'description': '', 'tags': [], 'useCases': []},
                        'nodes': [node], 'edges': [], 'requirements': {'capabilities': [], 'permissions': []}}
            with self.subTest(kind=kind):
                self.assertTrue(validator.is_valid(template))
                invalid = copy.deepcopy(template)
                invalid['nodes'][0]['credential'] = 'fixture'
                self.assertFalse(validator.is_valid(invalid))

    def test_schema_has_no_remote_references(self):
        document = json.loads((ROOT / 'template-exchange-v1.schema.json').read_text())
        def inspect(value):
            if isinstance(value, dict):
                if '$ref' in value:
                    self.assertTrue(value['$ref'].startswith('#/'))
                for child in value.values():
                    inspect(child)
            elif isinstance(value, list):
                for child in value:
                    inspect(child)
        inspect(document)
