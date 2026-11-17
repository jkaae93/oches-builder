"""Compare default parsers using synthetic input; this is not a JCS verifier."""
import json
import platform
import subprocess

DUPLICATE = '{"role":"read","role":"write"}'
BIG_INTEGER = '9007199254740993'
program = r'''
const duplicate = JSON.parse('{"role":"read","role":"write"}');
const value = JSON.parse('9007199254740993');
console.log(JSON.stringify({
  version: process.version,
  duplicate: duplicate.role,
  bigIntegerAsString: String(value),
  unicodeSame: '\u00e9' === 'e\u0301'
}));
'''

node = json.loads(subprocess.check_output(['node', '-e', program], text=True))
python = {
    'version': platform.python_version(),
    'duplicate': json.loads(DUPLICATE)['role'],
    'bigIntegerAsString': str(json.loads(BIG_INTEGER)),
    'unicodeSame': '\u00e9' == 'e\u0301',
}
print(json.dumps({'node': node, 'python': python}, ensure_ascii=False, indent=2))
