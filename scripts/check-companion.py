#!/usr/bin/env python3
"""Verify that companion shapes and expressions retain their original data."""
import hashlib
import json
from pathlib import Path

ASSET = Path(__file__).resolve().parents[1] / "Sources/Vela/Assets/pet.json"
EXPECTED_SHA256 = "443692cce03480f71462c056648f4662c2f28b9cc3b43e8e5adc0b322132472c"


def check():
    raw = ASSET.read_bytes()
    data = json.loads(raw)
    assert len(data["shapes"]) == 19, "A companion shape was removed"
    assert len(data["eyes"]) == 25, "An original eye pose was removed"
    assert len(data["moods"]) == 39, "An original expression record was removed"
    for pair in data["eyes"]:
        assert len(pair) == 2 and all(len(eye) == 48 for eye in pair)
    for mood in data["moods"].values():
        assert mood["eyes"] and all(0 <= pose < 25 for pose in mood["eyes"])
        assert len(mood["holdSeconds"]) == 2 and all(value > 0 for value in mood["holdSeconds"])
        blink = mood["blinkSeconds"]
        assert blink is None or (len(blink) == 2 and all(value > 0 for value in blink))
    assert hashlib.sha256(raw).hexdigest() == EXPECTED_SHA256, "Original geometry, eye poses, or expression timing changed"
    print("PASS: 19 shapes, 25 eye poses, and 39 expression records match the original asset")


if __name__ == "__main__":
    check()
