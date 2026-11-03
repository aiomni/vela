#!/usr/bin/env python3
"""Check dense actual-render signals for aliasing, independently of beat amplitude.

Requires NumPy. The previous adjacent-frame change limits remain unchanged;
these diagnostics do not turn their failures into passes or establish visual
acceptance. Limits are defined here before inspecting the captured signals.
"""
import argparse
import json
from pathlib import Path

import numpy as np

MAX_HIGH_FREQUENCY_ENERGY = 0.02
MIN_VISIBLE_SIGNAL_RMS = 0.01
MAX_LOCAL_EXPOSURE_ERROR = 0.035
MAX_MEAN_EXPOSURE_ERROR = 0.005


def check(path: Path) -> dict:
    meta = json.loads(path.read_text())
    assert meta["format"] == "float32-little-endian"
    assert meta["sampleRate"] == 96 and meta["channels"] == 3
    signals = np.fromfile(path.with_name(meta["binary"]), dtype="<f4")
    shape = (meta["samples"], meta["rows"] * meta["columns"], 3)
    assert signals.size == int(np.prod(shape))
    signals = signals.reshape(shape).astype(np.float64)
    assert np.isfinite(signals).all()
    centered = signals - signals.mean(axis=0, keepdims=True)
    visible = np.sqrt(np.mean(centered**2, axis=0)) >= MIN_VISIBLE_SIGNAL_RMS
    spectrum = np.fft.rfft(centered * np.hanning(shape[0])[:, None, None], axis=0)
    energy = np.abs(spectrum)**2
    frequency = np.fft.rfftfreq(shape[0], 1 / meta["sampleRate"])
    total = energy[1:].sum(axis=0)
    high = energy[frequency > 12].sum(axis=0)
    ratio = np.divide(high, total, out=np.zeros_like(high), where=total > 0)
    worst_high = float(ratio[visible].max()) if visible.any() else 0.0
    # Compare the actual 24-phase/s point samples with a centered one-frame
    # exposure integrated from the denser reference; amplitude itself is free.
    centers = np.arange(4, shape[0] - 4, 4)
    exposure = sum(weight * signals[centers + offset] for offset, weight in
                   [(-2, .125), (-1, .25), (0, .25), (1, .25), (2, .125)])
    error = np.abs(signals[centers] - exposure).mean(axis=2)
    worst_local = float(error.max())
    worst_mean = float(error.mean(axis=1).max())
    passed = (visible.any() and worst_high < MAX_HIGH_FREQUENCY_ENERGY
              and worst_local < MAX_LOCAL_EXPOSURE_ERROR
              and worst_mean < MAX_MEAN_EXPOSURE_ERROR)
    report = {
        "palette": meta["palette"], "bodyPixels": meta["bodyPixels"],
        "passed": bool(passed), "visiblePatchChannels": int(visible.sum()),
        "maxEnergyFractionAbove12Hz": worst_high,
        "maxLocalExposureError": worst_local,
        "maxMeanExposureError": worst_mean,
        "limits": {"highFrequencyEnergyFraction": MAX_HIGH_FREQUENCY_ENERGY,
                   "minimumVisibleSignalRMS": MIN_VISIBLE_SIGNAL_RMS,
                   "localExposureError": MAX_LOCAL_EXPOSURE_ERROR,
                   "meanExposureError": MAX_MEAN_EXPOSURE_ERROR},
        "scope": meta["scope"],
        "exclusions": "Does not establish native playback, eyes/interaction behavior or user visual acceptance; does not override legacy adjacent-frame check results.",
    }
    destination = path.with_name(path.stem + "-analysis.json")
    destination.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("captures", type=Path, nargs="+")
    args = parser.parse_args()
    reports = [check(path) for path in args.captures]
    raise SystemExit(0 if all(report["passed"] for report in reports) else 1)
