#!/usr/bin/env python3
"""Cross-process development-signing probe, not a Flutter or release test.

Set OCHES_SIGNING_IDENTITY and its actual OCHES_SIGNING_TEAM_ID. Compiles two
helper executables and creates three disposable app/XPC service bundles.
"""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import uuid

identity = os.environ.get("OCHES_SIGNING_IDENTITY")
team = os.environ.get("OCHES_SIGNING_TEAM_ID")
if not identity or not team:
    raise SystemExit("Set OCHES_SIGNING_IDENTITY and OCHES_SIGNING_TEAM_ID.")
if not team.isascii() or not team.isalnum():
    raise SystemExit("Invalid signing Team ID.")
root = Path(__file__).resolve().parents[3]
sources = sorted((root / "core/Sources/OchesCore").glob("*.swift"))

with tempfile.TemporaryDirectory(prefix="oches-xpc-service-") as temp:
    folder = Path(temp)
    run_id = uuid.uuid4().hex
    main = folder / "main.swift"
    main.write_text('''import Darwin
import Foundation
let info = Bundle.main.infoDictionary!
let team = info["ProbeTeam"] as! String
let expected = info["ProbeExpectedClient"] as! String
let pidFile = info["ProbePIDFile"] as! String
try String(getpid()).write(toFile: pidFile, atomically: true, encoding: .utf8)
let listener = NSXPCListener.service()
let gate = try AnalyzerXPCPeerBoundary(teamID: team, signingIdentifier: expected, expectedUID: getuid())
listener.delegate = gate
listener.resume()
withExtendedLifetime(gate) { dispatchMain() }
''')
    server = folder / "server"
    subprocess.run(["swiftc", *(str(p) for p in sources), str(main), "-o", str(server)], check=True, timeout=45)
    main.write_text('''import Darwin
import Foundation
let info = Bundle.main.infoDictionary!
let client = try AnalyzerXPCProbeClient(serviceName: info["ProbeService"] as! String, teamID: info["ProbeTeam"] as! String, signingIdentifier: info["ProbeExpectedServer"] as! String)
let done = DispatchSemaphore(value: 0)
print("PID:" + String(getpid()))
client.readiness(onError: { _ in print("ERROR"); done.signal() }, reply: { value in print("REPLY:" + value); done.signal() })
if done.wait(timeout: .now() + 10) == .timedOut { print("TIMEOUT"); exit(2) }
''')
    desktop = folder / "desktop"
    subprocess.run(["swiftc", *(str(p) for p in sources), str(main), "-o", str(desktop)], check=True, timeout=45)
    for mode in ("positive", "incoming", "outgoing"):
        app = folder / (mode + ".app")
        contents = app / "Contents"
        appbin = contents / "MacOS"
        service = contents / "XPCServices" / "Core.xpc"
        servicebin = service / "Contents" / "MacOS"
        appbin.mkdir(parents=True)
        servicebin.mkdir(parents=True)
        app_id = "com.oches.test.desktop." + run_id + "." + mode
        service_id = "com.oches.test.core." + run_id + "." + mode
        pidfile = folder / (mode + ".pid")
        app_info = {"CFBundleIdentifier": app_id, "CFBundleExecutable": "Probe", "CFBundleName": "Probe", "CFBundlePackageType": "APPL", "CFBundleVersion": "1.0", "ProbeTeam": team, "ProbeService": service_id, "ProbeExpectedServer": service_id if mode != "outgoing" else "com.oches.test.wrong"}
        service_info = {"CFBundleIdentifier": service_id, "CFBundleExecutable": "Core", "CFBundleName": "Core", "CFBundlePackageType": "XPC!", "CFBundleVersion": "1.0", "XPCService": {"ServiceType": "Application"}, "ProbeTeam": team, "ProbeExpectedClient": app_id if mode != "incoming" else "com.oches.test.wrong", "ProbePIDFile": str(pidfile)}
        (contents / "Info.plist").write_bytes(plistlib.dumps(app_info))
        (service / "Contents" / "Info.plist").write_bytes(plistlib.dumps(service_info))
        shutil.copy2(server, servicebin / "Core")
        shutil.copy2(desktop, appbin / "Probe")
        for target in (service, app):
            subprocess.run(["codesign", "--force", "--sign", identity, str(target)], check=True, timeout=30, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True, timeout=15)
        result = subprocess.run([str(appbin / "Probe")], capture_output=True, text=True, timeout=15, check=True)
        lines = result.stdout.splitlines()
        expected = "REPLY:unavailable" if mode == "positive" else "ERROR"
        pidline = next((line for line in lines if line.startswith("PID:")), "")
        if expected not in lines or not pidline or not pidfile.exists() or int(pidline[4:]) == int(pidfile.read_text()):
            raise SystemExit(f"{mode}: unexpected output or no separate service process: {lines!r}")
        print(f"{mode}: PASS (separate processes)")
print("Development-signing helper bundles only; Flutter and distribution tests NOT RUN.")
