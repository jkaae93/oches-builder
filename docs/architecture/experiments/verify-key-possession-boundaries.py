#!/usr/bin/env python3
"""Isolated cryptographic negative controls. No user keychain or product authentication."""
import os
import pathlib
import stat
import subprocess
import tempfile


def call(args):
    return subprocess.run(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode


with tempfile.TemporaryDirectory(prefix='oches-key-proof-') as directory:
    root = pathlib.Path(directory)
    key_a, key_b = root / 'a.pem', root / 'b.pem'
    pub_a, pub_b = root / 'a.pub', root / 'b.pub'
    message, altered, signature = root / 'message', root / 'altered', root / 'signature'
    for key, public in ((key_a, pub_a), (key_b, pub_b)):
        assert call(['openssl', 'ecparam', '-name', 'prime256v1', '-genkey', '-noout', '-out', str(key)]) == 0
        os.chmod(key, 0o600)
        assert stat.S_IMODE(key.stat().st_mode) == 0o600
        assert call(['openssl', 'ec', '-in', str(key), '-pubout', '-out', str(public)]) == 0
    message.write_bytes(b'oches isolated test: core-A client-A nonce-one')
    altered.write_bytes(b'oches isolated test: core-B client-A nonce-one')
    # This separate, same-user OpenSSL process can read the 0600 temporary file.
    assert call(['openssl', 'dgst', '-sha256', '-sign', str(key_a), '-out', str(signature), str(message)]) == 0
    def verify(public, data):
        return call(['openssl', 'dgst', '-sha256', '-verify', str(public), '-signature', str(signature), str(data)]) == 0
    assert verify(pub_a, message)
    assert verify(pub_a, message)  # replay remains cryptographically valid without protocol state
    assert not verify(pub_a, altered)
    assert not verify(pub_b, message)
    print('PASS: matching key; wrong key and changed message rejected; replay verifies; same-user 0600 file usable')
    print('NOT RUN: nonce store, authenticated channel, app identity, OS keychain, or Oches product')
