#!/usr/bin/env python3
"""
Cross-check the hand-mirrored uniform structs between Swift and MSL.

The Swift and Metal sides of this package describe the same memory twice, in two
languages, with no compiler linking them. Drift produces a visual glitch rather
than a build error, so it is checked here and pinned again in PipelineTests.

This script compares field order, field types and the resulting stride, and
verifies the strides asserted in PipelineTests still match what the layouts
actually produce.

Usage:  python3 Scripts/check-struct-parity.py
Exit:   0 if everything agrees, 1 otherwise.
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources" / "MetalVisualKit"
TESTS = ROOT / "Tests" / "MetalVisualKitTests" / "PipelineTests.swift"

# (size, alignment) per MSL's layout rules. Swift's SIMD types match these,
# which is the property that makes a straight field-order mirror correct.
LAYOUT = {
    "float": (4, 4),
    "float2": (8, 8),
    "float3": (16, 16),
    "float3x3": (48, 16),   # three 16-byte-aligned columns, not 36 bytes
    "float4x4": (64, 16),
}

SWIFT_TO_MSL = {
    "Float": "float",
    "SIMD2<Float>": "float2",
    "SIMD3<Float>": "float3",
    "simd_float3x3": "float3x3",
    "simd_float4x4": "float4x4",
}

# Swift struct name -> MSL struct name
PAIRS = {
    "LoaderUniforms": "LoaderUniforms",
    "LoaderParticle": "Particle",
    "CloudUniforms": "CloudUniforms",
    "DemoUniforms": "DemoUniforms",
}


def read(pattern: str) -> str:
    return "\n".join(path.read_text() for path in sorted(SOURCES.rglob(pattern)))


def swift_structs(text: str) -> dict[str, list[tuple[str, str]]]:
    found = {}
    for match in re.finditer(r"struct (\w+) \{(.*?)\n\}", text, re.S):
        fields = re.findall(r"var (\w+): ([\w<>]+)", match.group(2))
        if fields:
            found[match.group(1)] = fields
    return found


def msl_structs(text: str) -> dict[str, list[tuple[str, str]]]:
    found = {}
    for match in re.finditer(r"struct (\w+) \{(.*?)\n\};", text, re.S):
        body = re.sub(r"//.*", "", match.group(2))
        found[match.group(1)] = [
            (name, type_) for type_, name in re.findall(r"(\w+)\s+(\w+);", body)
        ]
    return found


def stride(fields: list[tuple[str, str]]) -> tuple[int, int]:
    """Offsets follow the C/MSL rule: pad each field up to its own alignment,
    then round the total up to the struct's alignment."""
    offset, alignment = 0, 1
    for _, raw_type in fields:
        type_ = SWIFT_TO_MSL.get(raw_type, raw_type)
        size, align = LAYOUT[type_]
        offset = -(-offset // align) * align
        offset += size
        alignment = max(alignment, align)
    return -(-offset // alignment) * alignment, alignment


def main() -> int:
    swift = swift_structs(read("*.swift"))
    metal = msl_structs(read("*.metal"))
    tests = TESTS.read_text()
    failures: list[str] = []

    for swift_name, msl_name in PAIRS.items():
        if swift_name not in swift:
            failures.append(f"Swift struct '{swift_name}' not found.")
            continue
        if msl_name not in metal:
            failures.append(f"MSL struct '{msl_name}' not found.")
            continue

        swift_fields, msl_fields = swift[swift_name], metal[msl_name]

        swift_names = [name for name, _ in swift_fields]
        msl_names = [name for name, _ in msl_fields]
        if swift_names != msl_names:
            failures.append(
                f"{swift_name}: field names differ.\n"
                f"  swift: {swift_names}\n  msl:   {msl_names}"
            )
            continue

        swift_types = [SWIFT_TO_MSL.get(type_, type_) for _, type_ in swift_fields]
        msl_types = [type_ for _, type_ in msl_fields]
        if swift_types != msl_types:
            failures.append(
                f"{swift_name}: field types differ.\n"
                f"  swift: {swift_types}\n  msl:   {msl_types}"
            )
            continue

        size, alignment = stride(swift_fields)

        asserted_size = re.search(
            rf"MemoryLayout<{swift_name}>\.stride, (\d+)", tests
        )
        asserted_align = re.search(
            rf"MemoryLayout<{swift_name}>\.alignment, (\d+)", tests
        )
        if not asserted_size or not asserted_align:
            failures.append(f"{swift_name}: PipelineTests has no stride assertion.")
            continue
        if int(asserted_size.group(1)) != size or int(asserted_align.group(1)) != alignment:
            failures.append(
                f"{swift_name}: PipelineTests asserts "
                f"{asserted_size.group(1)}/{asserted_align.group(1)}, "
                f"layout produces {size}/{alignment}."
            )
            continue

        print(
            f"  ok  {swift_name:<16} <-> {msl_name:<16} "
            f"{len(swift_fields)} fields, stride {size}, align {alignment}"
        )

    if failures:
        print("\nStruct parity check FAILED:\n", file=sys.stderr)
        for failure in failures:
            print(f"  {failure}", file=sys.stderr)
        return 1

    print("\nSwift and MSL struct layouts agree.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
