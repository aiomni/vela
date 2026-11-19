#!/usr/bin/env python3
"""Capture launch/creation results from a signed touch lab without sending input reports."""

import argparse
import hashlib
import json
from pathlib import Path
import signal
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--mode", choices=["probe", "activate-probe"], default="probe")
    parser.add_argument("--display-id", type=int, default=1)
    parser.add_argument("--output", type=Path, required=True)
    options = parser.parse_args()
    app = options.app.resolve()
    if not app.is_relative_to(ROOT / ".build" / "touch-lab") or app.name != "VelaTouchLab.app":
        raise RuntimeError("Use an isolated lab artifact under this workspace's .build/touch-lab")
    if not 0 < options.display_id <= 0xffffffff:
        raise RuntimeError("A valid existing display ID is required")
    if options.output.exists():
        raise RuntimeError("Evidence output must not already exist")
    verified = subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], capture_output=True, timeout=20)
    if verified.returncode:
        raise RuntimeError("The lab signature does not pass strict verification")
    executable = app / "Contents" / "MacOS" / "VelaTouchLab"
    child = subprocess.Popen([str(executable), "--" + options.mode, "--display-id", str(options.display_id)],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    forced_timeout = False
    try:
        stdout, stderr = child.communicate(timeout=22)
    except subprocess.TimeoutExpired:
        forced_timeout = True
        child.kill()
        stdout, stderr = child.communicate(timeout=5)
    record = {
        "appPath": str(app.relative_to(ROOT)),
        "executableSHA256": hashlib.sha256(executable.read_bytes()).hexdigest(),
        "signatureVerified": True, "mode": options.mode, "processID": child.pid,
        "processReturnCode": child.returncode,
        "terminationSignal": signal.Signals(-child.returncode).name if child.returncode < 0 else None,
        "runnerForcedTimeout": forced_timeout,
        "stderrBytes": len(stderr), "probeOutputReceived": False,
        "scope": "No-input probe modes only. Capturing a result is not successful HID authorization. Raw stderr/command lines/signing configuration are not saved.",
    }
    try:
        record["probe"] = json.loads(stdout)
        record["probeOutputReceived"] = True
    except (json.JSONDecodeError, UnicodeDecodeError):
        record["probe"] = None
    with options.output.open("x") as stream:
        json.dump(record, stream, indent=2)
        stream.write("\n")
    print(json.dumps(record, indent=2))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # Do not print raw subprocess arguments, stderr or paths from OS errors.
        print(f"ERROR: {error}" if isinstance(error, RuntimeError) else f"ERROR: Probe capture failed ({type(error).__name__})")
        raise SystemExit(1)
