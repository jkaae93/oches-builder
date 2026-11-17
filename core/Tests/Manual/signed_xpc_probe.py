#!/usr/bin/env python3
"""Manual same-process signed XPC check; never substitutes for product signing tests.

Set OCHES_SIGNING_IDENTITY to a codesign identity and OCHES_SIGNING_TEAM_ID to
its actual TeamIdentifier. Uses a temporary executable and never exports keys.
"""
import os
from pathlib import Path
import subprocess
import tempfile

identity = os.environ.get("OCHES_SIGNING_IDENTITY")
team = os.environ.get("OCHES_SIGNING_TEAM_ID")
if not identity or not team:
    raise SystemExit("Set OCHES_SIGNING_IDENTITY and OCHES_SIGNING_TEAM_ID.")
if not team.isascii() or not team.isalnum():
    raise SystemExit("Invalid signing Team ID.")
root = Path(__file__).resolve().parents[3]

with tempfile.TemporaryDirectory(prefix="oches-signed-xpc-") as temp:
    folder = Path(temp)
    (folder / "main.swift").write_text('''import Darwin
import Foundation
let team = CommandLine.arguments[1]
let mode = CommandLine.arguments[2]
let name = "com.oches.test.signedprobe"
let wrong = "com.oches.test.incorrect"
let listener = NSXPCListener.anonymous()
let gate = try AnalyzerXPCPeerBoundary(teamID: team, signingIdentifier: mode == "incoming" ? wrong : name, expectedUID: getuid())
listener.delegate = gate
listener.resume()
let client = try AnalyzerXPCProbeClient(endpoint: listener.endpoint, teamID: team, signingIdentifier: mode == "outgoing" ? wrong : name)
let done = DispatchSemaphore(value: 0)
client.readiness(onError: { _ in print("ERROR"); done.signal() }, reply: { result in print("REPLY:" + result); done.signal() })
if done.wait(timeout: .now() + 8) == .timedOut { print("TIMEOUT"); exit(2) }
withExtendedLifetime(gate) {}
''')
    executable = folder / "signed-probe"
    sources = sorted((root / "core/Sources/OchesCore").glob("*.swift"))
    subprocess.run(["swiftc", *(str(source) for source in sources), str(folder / "main.swift"), "-o", str(executable)], check=True, timeout=45)
    subprocess.run(["codesign", "--force", "--sign", identity, "--identifier", "com.oches.test.signedprobe", str(executable)], check=True, timeout=30, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["codesign", "--verify", "--strict", str(executable)], check=True, timeout=15)
    for mode, expected in [("positive", "REPLY:unavailable"), ("incoming", "ERROR"), ("outgoing", "ERROR")]:
        result = subprocess.run([str(executable), team, mode], capture_output=True, text=True, timeout=15, check=True)
        if result.stdout.strip() != expected:
            raise SystemExit(f"{mode}: unexpected result {result.stdout.strip()!r}")
        print(f"{mode}: PASS")
print("Same-process development-signing probe only; product and cross-process tests NOT RUN.")
