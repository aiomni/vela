#!/usr/bin/env python3
"""Build an isolated CoreHID lab with the existing fixed certificate, never production apps."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
ENTITLEMENT = "com.apple.developer.hid.virtual.device"


def checked(arguments, stage, timeout=240):
    # Never include arguments or codesign diagnostics: they can expose local signing configuration.
    try:
        result = subprocess.run(arguments, cwd=ROOT, capture_output=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        raise RuntimeError(f"{stage} could not complete") from None
    if result.returncode:
        raise RuntimeError(f"{stage} failed (exit {result.returncode}); no signing fallback")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--configuration", choices=["debug", "release"], default="debug")
    parser.add_argument("--control-without-hid-entitlement", action="store_true",
                        help="Build a separate same-certificate no-HID-entitlement control, never a fallback")
    options = parser.parse_args()
    identity = os.environ.get("SIGNING_IDENTITY", "")
    if not identity and (ROOT / ".signing-identity.local").is_file():
        identity = (ROOT / ".signing-identity.local").read_text().strip()
    if not identity or identity.strip() == "-":
        raise RuntimeError("An existing fixed signing identity is required; no ad-hoc fallback")
    keychain = ["--keychain", os.environ["SIGNING_KEYCHAIN"]] if os.environ.get("SIGNING_KEYCHAIN") else []
    checked(["swift", "build", "-c", options.configuration, "--product", "VelaTouchLab"], "Lab build")
    binary_directory = Path(checked(["swift", "build", "-c", options.configuration, "--show-bin-path"],
                                   "Build path query").stdout.decode().strip())
    if not binary_directory.is_absolute() or not (binary_directory / "VelaTouchLab").is_file():
        raise RuntimeError("Build did not return a valid absolute binary directory")
    directory = ROOT / ".build" / "touch-lab" / str(uuid.uuid4())
    directory.mkdir(parents=True, exist_ok=False)
    app = directory / "VelaTouchLab.app"
    executable = app / "Contents" / "MacOS" / "VelaTouchLab"
    executable.parent.mkdir(parents=True)
    resources = app / "Contents" / "Resources"
    resources.mkdir()
    shutil.copy2(binary_directory / "VelaTouchLab", executable)
    shutil.copytree(binary_directory / "Vela_VelaLocalization.bundle", resources / "Vela_VelaLocalization.bundle")
    info = {
        "CFBundleIdentifier": "app.aiomni.awakepet.touchlab",
        "CFBundleExecutable": "VelaTouchLab", "CFBundleName": "Vela Touch Lab",
        "CFBundleDisplayName": "Vela Touch Lab", "CFBundlePackageType": "APPL",
        "CFBundleVersion": "1", "CFBundleShortVersionString": "0.0.1",
        "LSMinimumSystemVersion": "26.0", "NSHighResolutionCapable": True,
        "CFBundleDevelopmentRegion": "en", "CFBundleLocalizations": ["en", "zh-Hans"],
    }
    (app / "Contents" / "Info.plist").write_bytes(plistlib.dumps(info))
    entitlement_file = directory / "lab.entitlements.plist"
    requested_claims = {} if options.control_without_hid_entitlement else {ENTITLEMENT: True}
    entitlement_file.write_bytes(plistlib.dumps(requested_claims))

    # Match the existing workflow's certificate preflight without changing trust or identities.
    certificate_probe = directory / "certificate-probe"
    # Copy bytes and executable permissions, not SIP-only source metadata flags.
    shutil.copyfile("/usr/bin/true", certificate_probe)
    certificate_probe.chmod(0o755)
    checked(["codesign", "--force", "--options", "0", "--timestamp=none", *keychain,
             "--sign", identity, str(certificate_probe)], "Fixed certificate preflight")
    checked(["codesign", "--verify", "--strict", str(certificate_probe)], "Certificate signature verification")
    metadata = checked(["codesign", "--display", "--verbose=4", str(certificate_probe)], "Signature metadata query")
    lines = metadata.stderr.decode(errors="replace").splitlines()
    team = next((line.partition("=")[2] for line in lines if line.startswith("TeamIdentifier=")), "")
    has_team = bool(team and team != "not set")
    timestamp = "--timestamp" if has_team else "--timestamp=none"
    # Hardened runtime stays enabled even with a local fixed certificate; no security-policy relaxation.
    checked(["codesign", "--force", "--options", "runtime", timestamp, *keychain,
             "--entitlements", str(entitlement_file), "--sign", identity, str(app)], "Entitled lab signing")
    checked(["codesign", "--verify", "--deep", "--strict", str(app)], "Lab signature verification")
    checked(["plutil", "-lint", str(app / "Contents" / "Info.plist")], "Lab property-list verification")
    requirements = checked(["codesign", "--display", "--requirements", "-", str(app)], "Designated requirement query")
    requirement_text = (requirements.stdout + requirements.stderr).decode(errors="replace")
    designated = next((line for line in requirement_text.splitlines() if line.startswith("designated =>")), "")
    if "certificate" not in designated:
        raise RuntimeError("The lab signature lacks a certificate-bound designated requirement")
    signed_entitlements = checked(["codesign", "--display", "--entitlements", "-", "--xml", str(app)],
                                  "Signed entitlement query")
    claims = plistlib.loads(signed_entitlements.stdout)
    if claims != requested_claims or (not options.control_without_hid_entitlement and type(claims.get(ENTITLEMENT)) is not bool):
        raise RuntimeError("The signed lab does not contain exactly the requested entitlement set")
    apple_anchor = subprocess.run(["codesign", "--verify", "--strict", "--test-requirement", "anchor apple generic", str(app)],
                                  cwd=ROOT, capture_output=True, timeout=20)
    evidence = {
        "appPath": str(app.relative_to(ROOT)),
        "buildExecutableSHA256": hashlib.sha256((binary_directory / "VelaTouchLab").read_bytes()).hexdigest(),
        "executableSHA256": hashlib.sha256(executable.read_bytes()).hexdigest(),
        "fixedCertificateSignatureVerified": True,
        "certificateBoundDesignatedRequirement": True,
        "hardenedRuntimeEnabled": True,
        "signatureHasTeamIdentifier": has_team,
        "appleSigningAnchorVerified": apple_anchor.returncode == 0,
        "signedVirtualDeviceEntitlement": claims.get(ENTITLEMENT, False),
        "controlWithoutHIDEntitlement": options.control_without_hid_entitlement,
        "provisioningProfileEmbedded": False,
        "runtimeAuthorizationVerified": False,
        "scope": "Isolated lab only. No certificate, keychain trust, production app or permission changes. Signing claims do not establish runtime HID authorization.",
    }
    evidence_file = directory / "signing-evidence.json"
    evidence_file.write_text(json.dumps(evidence, indent=2) + "\n")
    print(json.dumps(evidence, indent=2))
    print(f"Signing evidence: {evidence_file.relative_to(ROOT)}")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # No traceback, subprocess arguments, raw signature metadata or certificate configuration.
        if isinstance(error, RuntimeError):
            print(f"ERROR: {error}")
        else:
            print(f"ERROR: Isolated lab packaging failed ({type(error).__name__})")
        raise SystemExit(1)
