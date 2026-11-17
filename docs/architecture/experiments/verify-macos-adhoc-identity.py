#!/usr/bin/env python3
"""Isolated macOS ad-hoc identity negative control; not a product security test."""
import hashlib
import pathlib
import platform
import subprocess
import tempfile

if platform.system() != 'Darwin':
    raise SystemExit('NOT RUN: macOS required')
with tempfile.TemporaryDirectory(prefix='oches-signcheck-') as temp:
    root = pathlib.Path(temp)
    first, second = root / 'first', root / 'second'
    for binary, label in ((first, 'first fixture'), (second, 'second fixture')):
        source = root / (binary.name + '.c')
        source.write_text('#include <stdio.h>\nint main(void){ puts("' + label + '"); return 0; }\n')
        subprocess.run(['clang', str(source), '-o', str(binary)], capture_output=True, check=True)
        subprocess.run(['codesign', '--force', '--sign', '-', '--identifier',
                        'test.local.oches.identity', str(binary)], capture_output=True, check=True)
    assert hashlib.sha256(first.read_bytes()).digest() != hashlib.sha256(second.read_bytes()).digest()
    for binary in (first, second):
        assert subprocess.run(['codesign', '--verify', '--strict', str(binary)], capture_output=True).returncode == 0
        assert subprocess.run(['codesign', '--verify', '-R',
                               '=identifier "test.local.oches.identity"', str(binary)],
                              capture_output=True).returncode == 0
    assert subprocess.run(['codesign', '--verify', '-R',
                           '=anchor apple generic and identifier "test.local.oches.identity"', str(second)],
                          capture_output=True).returncode != 0
    contents = bytearray(second.read_bytes())
    assert len(contents) > 4096
    contents[4096] ^= 1
    second.write_bytes(contents)
    assert subprocess.run(['codesign', '--verify', '--strict', str(second)], capture_output=True).returncode != 0
    print('PASS: identifier-only accepts two distinct ad-hoc binaries; anchor and tamper negative controls rejected')
    print('NOT RUN: trusted signed positive control, live IPC identity, key protection, and Oches product test')
