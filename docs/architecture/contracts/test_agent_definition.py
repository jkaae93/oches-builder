"""Contract tests validate a deliberately narrow example, not deployed behavior."""
import copy
import json
from pathlib import Path
import unittest
from check_agent_definition import check, decode

BASE = {"schemaVersion":{"major":1,"minor":0}, "definitionId":"agent-1", "revision":1, "role":"worker", "instructions":"review", "inputs":[], "outputs":[], "tools":[], "permissions":[], "resourceLimits":{"maxDurationSeconds":60, "maxAttempts":1}}

class ContractTests(unittest.TestCase):
    def test_documented_example(self):
        source = (Path(__file__).parent.parent / 'ARC-15.md').read_text()
        sample = json.loads(source.split('```json\n', 1)[1].split('\n```', 1)[0])
        self.assertEqual([], check(sample['nodes'][0]['definition']))
    def test_valid_ports_and_permission(self):
        x=copy.deepcopy(BASE); x['inputs']=[{'portId':'prompt','type':'text','required':True}]; x['permissions']=[{'action':'read','scope':'workspace','approvalRequired':True}]
        self.assertEqual([],check(x))
    def test_rejections(self):
        mutations = [
            lambda x:x.pop('instructions'),
            lambda x:x.update(schemaVersion={'major':2,'minor':0}),
            lambda x:x.update(schemaVersion={'major':1,'minor':1}),
            lambda x:x.update(schemaVersion='1.0'),
            lambda x:x.update(schemaVersion={'major':1}),
            lambda x:x.update(credential='secret'),
            lambda x:x.update(role=' '),
            lambda x:x.update(revision=0),
            lambda x:x['resourceLimits'].update(maxAttempts=0),
            lambda x:x['resourceLimits'].update(maxDurationSeconds=86401),
            lambda x:x.update(tools=['x','x']),
            lambda x:x.update(inputs=[{'portId':'a','type':'unknown','required':True}]),
            lambda x:x.update(inputs=[{'portId':'a','type':'text','required':True},{'portId':'a','type':'json','required':False}]),
            lambda x:x.update(permissions=[{'action':'write','scope':'workspace'}]),
            lambda x:x.update(inputs=[{'portId':'a','type':'text','required':1}]),
        ]
        for mutate in mutations:
            x=copy.deepcopy(BASE); mutate(x)
            with self.subTest(x=x): self.assertTrue(check(x))
    def test_reject_duplicate_keys(self):
        with self.assertRaises(ValueError): decode(b'{"x":1,"x":2}')
    def test_reject_nan(self):
        with self.assertRaises(ValueError): decode(b'{"x":NaN}')
    def test_reject_oversized(self):
        with self.assertRaises(ValueError): decode(b' ' * 262145)
    def test_reject_invalid_utf8(self):
        with self.assertRaises(UnicodeDecodeError): decode(b'\xff')

if __name__ == '__main__': unittest.main(verbosity=2)
