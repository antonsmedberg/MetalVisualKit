#!/usr/bin/env python3
"""
Pick an iOS simulator that actually exists on this machine and print an
xcodebuild -destination string for it.

Hard-coding `name=iPhone 16 Pro` works until the GitHub runner image rotates its
simulator set, and then the build fails for a reason that has nothing to do with
the code. This asks CoreSimulator what is installed instead.

Selection: newest installed iOS runtime, then an available iPhone on it,
preferring a Pro model.

Usage:
    python3 Scripts/select-ios-simulator.py
    xcodebuild build -scheme MetalVisualKit \\
        -destination "$(python3 Scripts/select-ios-simulator.py)"

Exit: 0 and the destination string on stdout, or 1 and a diagnostic on stderr.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys


def runtime_sort_key(identifier: str) -> tuple[int, ...]:
    """Order runtimes by version, so iOS 26.4 beats iOS 9.3 rather than losing
    a string comparison to it."""
    match = re.search(r"iOS-([\d-]+)$", identifier)
    if not match:
        return (0,)
    return tuple(int(part) for part in match.group(1).split("-"))


def device_rank(name: str) -> tuple[int, int]:
    """Prefer Pro, then Pro Max, then anything; break ties by model number."""
    tier = 2 if "Pro" in name else 0
    number = re.search(r"iPhone\s+(\d+)", name)
    return (tier, int(number.group(1)) if number else 0)


def main() -> int:
    try:
        raw = subprocess.run(
            ["xcrun", "simctl", "list", "devices", "available", "--json"],
            capture_output=True, text=True, check=True,
        ).stdout
    except FileNotFoundError:
        print("xcrun not found — this script only runs on macOS.", file=sys.stderr)
        return 1
    except subprocess.CalledProcessError as error:
        print(f"simctl failed: {error.stderr}", file=sys.stderr)
        return 1

    devices = json.loads(raw).get("devices", {})
    ios_runtimes = [key for key in devices if "iOS" in key]
    if not ios_runtimes:
        print("No iOS simulator runtimes are installed.", file=sys.stderr)
        return 1

    for runtime in sorted(ios_runtimes, key=runtime_sort_key, reverse=True):
        iphones = [
            device for device in devices[runtime]
            if device.get("isAvailable") and "iPhone" in device.get("name", "")
        ]
        if not iphones:
            continue
        chosen = max(iphones, key=lambda device: device_rank(device["name"]))
        print(f"platform=iOS Simulator,id={chosen['udid']}")
        print(
            f"Selected {chosen['name']} on {runtime.split('.')[-1]}",
            file=sys.stderr,
        )
        return 0

    print("No available iPhone simulator on any installed runtime.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
