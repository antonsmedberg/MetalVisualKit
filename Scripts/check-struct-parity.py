#!/usr/bin/env python3
"""
Cross-check the hand-mirrored GPU structs between Swift and Metal Shading
Language.

The Swift and Metal sides describe the same memory layout independently.
A mismatch can compile successfully while corrupting GPU data at runtime, so
this script validates:

1. Struct presence.
2. Field order.
3. Field types.
4. Computed MSL-compatible stride and alignment.
5. Matching MemoryLayout assertions somewhere in the Swift test suite.

Usage:
    python3 Scripts/check-struct-parity.py

Exit status:
    0 if all mirrored layouts agree.
    1 if any mismatch is detected.
"""

from __future__ import annotations

import pathlib
import re
import sys


ROOT = pathlib.Path(__file__).resolve().parent.parent

SOURCES = ROOT / "Sources" / "MetalVisualKit"
TESTS = ROOT / "Tests" / "MetalVisualKitTests"


# ---------------------------------------------------------------------------
# GPU layout model
# ---------------------------------------------------------------------------

# (size, alignment) according to the Metal Shading Language layout rules.
#
# Swift SIMD storage matches these layouts for the types mirrored by this
# package. float3 deliberately occupies 16 bytes rather than 12 in an aligned
# struct, and float3x3 consists of three 16-byte-aligned columns.
LAYOUT: dict[str, tuple[int, int]] = {
    "float": (4, 4),
    "float2": (8, 8),
    "float3": (16, 16),
    "float3x3": (48, 16),
    "float4x4": (64, 16),
}


SWIFT_TO_MSL: dict[str, str] = {
    "Float": "float",
    "SIMD2<Float>": "float2",
    "SIMD3<Float>": "float3",
    "simd_float3x3": "float3x3",
    "simd_float4x4": "float4x4",
}


# Swift struct name -> MSL struct name
PAIRS: dict[str, str] = {
    "LoaderUniforms": "LoaderUniforms",
    "LoaderParticle": "Particle",
    "CloudUniforms": "CloudUniforms",
    "DemoUniforms": "DemoUniforms",
}


# ---------------------------------------------------------------------------
# Source loading
# ---------------------------------------------------------------------------


def read_all(root: pathlib.Path, pattern: str) -> str:
    """Read and concatenate every matching source file below root."""
    paths = sorted(root.rglob(pattern))

    return "\n".join(
        path.read_text(encoding="utf-8")
        for path in paths
    )


# ---------------------------------------------------------------------------
# Swift / Metal parsing
# ---------------------------------------------------------------------------


def swift_structs(
    text: str,
) -> dict[str, list[tuple[str, str]]]:
    found: dict[str, list[tuple[str, str]]] = {}

    for match in re.finditer(
        r"struct\s+(\w+)\s*\{(.*?)\n\}",
        text,
        re.S,
    ):
        fields = re.findall(
            r"\bvar\s+(\w+)\s*:\s*([\w<>]+)",
            match.group(2),
        )

        if fields:
            found[match.group(1)] = fields

    return found


def msl_structs(
    text: str,
) -> dict[str, list[tuple[str, str]]]:
    found: dict[str, list[tuple[str, str]]] = {}

    for match in re.finditer(
        r"struct\s+(\w+)\s*\{(.*?)\n\};",
        text,
        re.S,
    ):
        body = re.sub(
            r"//.*",
            "",
            match.group(2),
        )

        fields = [
            (name, type_)
            for type_, name in re.findall(
                r"(\w+)\s+(\w+)\s*;",
                body,
            )
        ]

        found[match.group(1)] = fields

    return found


# ---------------------------------------------------------------------------
# Layout calculation
# ---------------------------------------------------------------------------


def align_up(
    value: int,
    alignment: int,
) -> int:
    return -(-value // alignment) * alignment


def stride(
    fields: list[tuple[str, str]],
) -> tuple[int, int]:
    """
    Compute C/MSL-style struct stride and alignment.

    Every field starts at an offset satisfying its own alignment requirement,
    and the final struct size is rounded to the maximum member alignment.
    """

    offset = 0
    struct_alignment = 1

    for _, raw_type in fields:
        type_name = SWIFT_TO_MSL.get(
            raw_type,
            raw_type,
        )

        if type_name not in LAYOUT:
            raise KeyError(
                f"Unsupported mirrored GPU type: {raw_type}"
            )

        size, field_alignment = LAYOUT[type_name]

        offset = align_up(
            offset,
            field_alignment,
        )

        offset += size

        struct_alignment = max(
            struct_alignment,
            field_alignment,
        )

    return (
        align_up(
            offset,
            struct_alignment,
        ),
        struct_alignment,
    )


# ---------------------------------------------------------------------------
# Test assertion validation
# ---------------------------------------------------------------------------


def asserted_layout(
    tests: str,
    struct_name: str,
) -> tuple[int, int] | None:
    """
    Find MemoryLayout stride/alignment assertions anywhere in the test suite.

    Whitespace is deliberately flexible so assertions remain discoverable
    after swift-format wraps them across multiple lines.
    """

    stride_match = re.search(
        rf"""
        MemoryLayout
        \s*<\s*{re.escape(struct_name)}\s*>
        \s*\.stride
        \s*,\s*
        (\d+)
        """,
        tests,
        re.X | re.S,
    )

    alignment_match = re.search(
        rf"""
        MemoryLayout
        \s*<\s*{re.escape(struct_name)}\s*>
        \s*\.alignment
        \s*,\s*
        (\d+)
        """,
        tests,
        re.X | re.S,
    )

    if not stride_match or not alignment_match:
        return None

    return (
        int(stride_match.group(1)),
        int(alignment_match.group(1)),
    )


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------


def validate_pair(
    swift_name: str,
    msl_name: str,
    swift: dict[str, list[tuple[str, str]]],
    metal: dict[str, list[tuple[str, str]]],
    tests: str,
) -> list[str]:
    failures: list[str] = []

    if swift_name not in swift:
        return [
            f"Swift struct '{swift_name}' not found."
        ]

    if msl_name not in metal:
        return [
            f"MSL struct '{msl_name}' not found."
        ]

    swift_fields = swift[swift_name]
    msl_fields = metal[msl_name]

    swift_names = [
        name
        for name, _ in swift_fields
    ]

    msl_names = [
        name
        for name, _ in msl_fields
    ]

    if swift_names != msl_names:
        return [
            (
                f"{swift_name}: field names differ.\n"
                f"  swift: {swift_names}\n"
                f"  msl:   {msl_names}"
            )
        ]

    swift_types = [
        SWIFT_TO_MSL.get(
            type_name,
            type_name,
        )
        for _, type_name in swift_fields
    ]

    msl_types = [
        type_name
        for _, type_name in msl_fields
    ]

    if swift_types != msl_types:
        return [
            (
                f"{swift_name}: field types differ.\n"
                f"  swift: {swift_types}\n"
                f"  msl:   {msl_types}"
            )
        ]

    expected_stride, expected_alignment = stride(
        swift_fields
    )

    assertion = asserted_layout(
        tests,
        swift_name,
    )

    if assertion is None:
        failures.append(
            (
                f"{swift_name}: test suite has no "
                "MemoryLayout stride/alignment assertions."
            )
        )

        return failures

    asserted_stride, asserted_alignment = assertion

    if (
        asserted_stride != expected_stride
        or asserted_alignment != expected_alignment
    ):
        failures.append(
            (
                f"{swift_name}: tests assert "
                f"{asserted_stride}/{asserted_alignment}, "
                f"but mirrored layout produces "
                f"{expected_stride}/{expected_alignment}."
            )
        )

        return failures

    print(
        f"  ok  {swift_name:<16} "
        f"<-> {msl_name:<16} "
        f"{len(swift_fields)} fields, "
        f"stride {expected_stride}, "
        f"align {expected_alignment}"
    )

    return failures


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def main() -> int:
    swift_source = read_all(
        SOURCES,
        "*.swift",
    )

    metal_source = read_all(
        SOURCES,
        "*.metal",
    )

    test_source = read_all(
        TESTS,
        "*.swift",
    )

    swift = swift_structs(
        swift_source
    )

    metal = msl_structs(
        metal_source
    )

    failures: list[str] = []

    for swift_name, msl_name in PAIRS.items():
        failures.extend(
            validate_pair(
                swift_name,
                msl_name,
                swift,
                metal,
                test_source,
            )
        )

    if failures:
        print(
            "\nStruct parity check FAILED:\n",
            file=sys.stderr,
        )

        for failure in failures:
            print(
                f"  {failure}",
                file=sys.stderr,
            )

        return 1

    print(
        "\nSwift and MSL struct layouts agree."
    )

    return 0


if __name__ == "__main__":
    sys.exit(main())
