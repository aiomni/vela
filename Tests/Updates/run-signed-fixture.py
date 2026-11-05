#!/usr/bin/env python3
"""Exercise replacement and LaunchServices relaunch using inert apps and the existing certificate."""
import os
import platform
import plistlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
identity = os.environ.get("SIGNING_IDENTITY", "")
if not identity and (ROOT / ".signing-identity.local").is_file():
    identity = (ROOT / ".signing-identity.local").read_text().strip()
if not identity or identity == "-":
    raise SystemExit("A fixed signing identity is required; no ad-hoc fallback is allowed.")

def run(arguments, **kwargs):
    result = subprocess.run(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kwargs)
    if result.returncode:
        raise RuntimeError("Signed fixture command failed")
    return result

binary = ROOT / ".build/update-fixture"
run(["swiftc", "-swift-version", "6", "-parse-as-library", "-target", f"{platform.machine()}-apple-macos26.0",
     *map(str, sorted((ROOT / "Sources/AppUpdateCore").glob("*.swift"))),
     str(ROOT / "Tests/Updates/Fixture.swift"), "-o", str(binary)])
keychain = ["--keychain", os.environ["SIGNING_KEYCHAIN"]] if os.environ.get("SIGNING_KEYCHAIN") else []

def app(path, version, controller=False):
    executable = "VelaConnect" if controller else "Vela"
    resources = path / "Contents"
    (resources / "MacOS").mkdir(parents=True)
    info = {"CFBundleIdentifier": "app.aiomni.awakepet.remoteviewer" if controller else "app.aiomni.awakepet",
            "CFBundleExecutable": executable, "CFBundleName": executable, "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1", "CFBundleShortVersionString": version,
            "LSMinimumSystemVersion": "26.0", "LSUIElement": True}
    (resources / "Info.plist").write_bytes(plistlib.dumps(info))
    shutil.copy2(binary, resources / "MacOS" / executable)
    if not controller:
        app(resources / "Applications/VelaConnect.app", version, controller=True)
    run(["codesign", "--force", "--options", "0", "--timestamp=none", *keychain, "--sign", identity, str(path)])

with tempfile.TemporaryDirectory(prefix="Vela-update-fixture-") as scratch:
    directory = Path(scratch)
    installed = directory / "installed/Vela.app"
    candidate = directory / "incoming/Vela.app"
    app(installed, "0.0.3")
    app(candidate, "0.0.4")
    run([str(binary), "--validate-fixture", str(installed)])
    run([str(binary), "--validate-fixture", str(candidate)])
    # The already-exited fixture process substitutes for the old application PID.
    child = subprocess.Popen(["/usr/bin/true"])
    child.wait()
    run([str(binary), "--install-fixture", str(candidate), str(installed), str(child.pid)])
    marker = installed.parent / "relaunched-version.txt"
    for _ in range(100):
        if marker.exists():
            break
        time.sleep(.1)
    assert marker.read_text() == "0.0.4", "LaunchServices did not launch the replacement"
    run([str(binary), "--validate-fixture", str(installed)])
    with (installed / "Contents/Info.plist").open("ab") as file:
        file.write(b"\n")
    rejected = subprocess.run([str(binary), "--validate-fixture", str(installed)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    assert rejected.returncode != 0, "Modified signed resources must be rejected"
print("PASS: fixed-certificate validation, isolated application replacement, LaunchServices relaunch, and tamper rejection")
