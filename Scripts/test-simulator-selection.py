#!/usr/bin/env python3
"""
Tests for the simulator selector's ordering logic.

Dependency-free and runnable on any host, including the Linux CI lane. Only the
pure functions are covered — the simctl call itself needs macOS.
"""

from __future__ import annotations

import importlib.util
import pathlib
import sys

SCRIPT = pathlib.Path(__file__).resolve().parent / "select-ios-simulator.py"
spec = importlib.util.spec_from_file_location("selector", SCRIPT)
selector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(selector)

failures: list[str] = []


def check(condition: bool, description: str) -> None:
    if condition:
        print(f"  ok  {description}")
    else:
        failures.append(description)
        print(f"  FAIL  {description}")


def main() -> int:
    print("Simulator selector")

    # The bug this guards against: a plain string sort puts iOS-9-3 above
    # iOS-26-4, so CI would silently target an ancient runtime.
    runtimes = [
        "com.apple.CoreSimulator.SimRuntime.iOS-9-3",
        "com.apple.CoreSimulator.SimRuntime.iOS-26-4",
        "com.apple.CoreSimulator.SimRuntime.iOS-18-2",
    ]
    newest = max(runtimes, key=selector.runtime_sort_key)
    check("iOS-26-4" in newest, "newest runtime wins over lexicographic order")

    check(
        selector.runtime_sort_key("com.apple.CoreSimulator.SimRuntime.iOS-26-4")
        > selector.runtime_sort_key("com.apple.CoreSimulator.SimRuntime.iOS-26-1"),
        "minor versions compare numerically",
    )
    check(
        selector.runtime_sort_key("com.apple.CoreSimulator.SimRuntime.watchOS-11-0")
        == (0,),
        "non-iOS runtime identifiers sort last",
    )

    devices = ["iPhone 16", "iPhone 17 Pro", "iPhone 16 Pro", "iPhone SE (3rd generation)"]
    check(
        max(devices, key=selector.device_rank) == "iPhone 17 Pro",
        "prefers the newest Pro handset",
    )
    check(
        selector.device_rank("iPhone 17 Pro") > selector.device_rank("iPhone 17"),
        "Pro outranks non-Pro at the same model number",
    )
    check(
        selector.device_rank("iPhone SE (3rd generation)") == (0, 0),
        "unnumbered models rank lowest without raising",
    )

    if failures:
        print(f"\n{len(failures)} check(s) failed.", file=sys.stderr)
        return 1
    print("\nAll simulator selector checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
