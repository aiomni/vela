#!/usr/bin/env python3
"""Validate release refs before using them in bundle versions or artifact paths."""
import os
import re
import subprocess


def metadata(tag, build, publish):
    if not re.fullmatch(r"[1-9][0-9]*", build):
        raise ValueError("Build number must be a positive integer")
    if not tag:
        raise ValueError("Release builds require an existing version tag")
    version, prerelease = "", False
    if tag:
        match = re.fullmatch(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?", tag)
        if not match:
            raise ValueError("Tag must be vMAJOR.MINOR.PATCH with an optional prerelease suffix")
        version = ".".join(match.group(1, 2, 3))
        prerelease = bool(match.group(4))
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("Bundle version must have three numeric components")
    return {"tag": tag, "version": version, "build": build,
            "publish": str(publish).lower(), "prerelease": str(prerelease).lower()}


if __name__ == "__main__":
    try:
        result = metadata(os.environ.get("RELEASE_TAG", ""), os.environ["GITHUB_RUN_NUMBER"],
                          os.environ.get("PUBLISH_RELEASE") == "true")
        if result["tag"]:
            tagged = subprocess.check_output(["git", "rev-parse", "--verify", f"refs/tags/{result['tag']}^{{commit}}"], text=True).strip()
            head = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
            if tagged != head:
                raise ValueError("The version tag must identify the checked-out commit")
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            output.writelines(f"{key}={value}\n" for key, value in result.items())
    except (ValueError, KeyError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"Release metadata error: {error}")
