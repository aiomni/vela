#!/usr/bin/env python3
"""Validate English source code, bilingual catalogs, and localized bundle metadata."""
import json
from pathlib import Path
import plistlib
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
HAN = re.compile(r"[\u3400-\u9fff]")
SLOTS = re.compile(r"\{\d+\}")
errors = []
native = json.loads((ROOT / "Sources/VelaLocalization/Resources/zh-Hans.json").read_text())
web = json.loads((ROOT / "Sources/RemoteServer/Web/locales/zh-Hans.json").read_text())
if native != web:
    errors.append("Native and web translation catalogs differ")
for english, chinese in native.items():
    if HAN.search(english) or not chinese:
        errors.append(f"Invalid catalog entry: {english!r}")
    if sorted(SLOTS.findall(english)) != sorted(SLOTS.findall(chinese)):
        errors.append(f"Placeholder mismatch: {english!r}")
for directory in ["Sources", "Tests", "scripts"]:
    for path in (ROOT / directory).rglob("*"):
        if path.suffix in {".swift", ".m", ".h", ".metal", ".js", ".cjs", ".html", ".css", ".py", ".sh"}:
            if HAN.search(path.read_text()):
                errors.append(f"Non-English source text: {path.relative_to(ROOT)}")
for name in ["Vela", "VelaConnect"]:
    info = plistlib.loads((ROOT / f"Resources/{name}Info.plist").read_bytes())
    if info.get("CFBundleDevelopmentRegion") != "en" or info.get("CFBundleLocalizations") != ["en", "zh-Hans"]:
        errors.append(f"Invalid bundle languages for {name}")
    if HAN.search(str(info)):
        errors.append(f"Non-English base bundle metadata for {name}")
    for language in ["en", "zh-Hans"]:
        if not (ROOT / f"Resources/{name}/{language}.lproj/InfoPlist.strings").exists():
            errors.append(f"Missing {language} bundle metadata for {name}")
for name in ["README.md", "AGENTS.md"]:
    path = ROOT / name
    if path.exists() and HAN.search(path.read_text()):
        errors.append(f"{name} must be English")
if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
print(f"PASS: English source, {len(native)} matching translations, and bilingual bundle metadata")
