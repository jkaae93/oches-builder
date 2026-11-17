"""Limited synthetic comparison, not a security audit or full RFC conformance test.

Requires Python rfc8785==0.1.4 and Node canonicalize==5.1.0. Set
JCS_NODE_MODULE to the latter's absolute module path.
"""
import json
import os
import subprocess
import rfc8785

cases = [
    {'z': [3, {'b': True, 'a': None}], 'a': 'text'},
    {'e_combined': 'é', 'e_separate': 'e\u0301', 'empty': ''},
    {'\ue000': 1, '\U00010000': 2, 'a': [2, 1]},
    {'integer': 9007199254740991, 'negative_zero': -0.0, 'decimal': 0.002},
    [333333333.33333329, 1e30, 4.50, 2e-3, 1e-27],
]
node_program = r'''
const canonicalize = require(process.env.JCS_NODE_MODULE).default;
const items = JSON.parse(require('fs').readFileSync(0, 'utf8'));
for (const item of items) console.log(Buffer.from(canonicalize(item), 'utf8').toString('hex'));
'''
node = subprocess.run(
    ['node', '-e', node_program], input=json.dumps(cases, ensure_ascii=True),
    text=True, capture_output=True, check=True, env=os.environ.copy(),
).stdout.splitlines()
python = [rfc8785.dumps(case).hex() for case in cases]
if len(node) != len(python):
    raise RuntimeError('unexpected result count')
for i, (left, right) in enumerate(zip(node, python), 1):
    print(f'case {i}: {"match" if left == right else "MISMATCH"} python={right} node={left}')
if node != python:
    raise SystemExit(1)
# RFC 8785 section 3.2.2 numeric example; compare against a fixed external oracle.
rfc_numeric = b'[333333333.3333333,1e+30,4.5,0.002,1e-27]'.hex()
if node[-1] != rfc_numeric or python[-1] != rfc_numeric:
    raise SystemExit('RFC 8785 numeric example mismatch')
print('RFC 8785 numeric example: both match')

invalid_node = r'''
const canonicalize = require(process.env.JCS_NODE_MODULE).default;
for (const value of ['\ud800', NaN, Infinity]) {
  try { canonicalize({value}); console.log('ACCEPTED'); }
  catch (_) { console.log('rejected'); }
}
'''
invalid_results = subprocess.run(
    ['node', '-e', invalid_node], text=True, capture_output=True,
    check=True, env=os.environ.copy(),
).stdout.splitlines()
for index, value in enumerate(['\ud800', float('nan'), float('inf')]):
    try:
        rfc8785.dumps({'value': value})
    except (ValueError, UnicodeError):
        python_result = 'rejected'
    else:
        python_result = 'ACCEPTED'
    print(f'invalid {index + 1}: python={python_result} node={invalid_results[index]}')
    if python_result != 'rejected' or invalid_results[index] != 'rejected':
        raise SystemExit(1)
