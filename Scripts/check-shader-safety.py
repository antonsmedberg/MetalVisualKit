#!/usr/bin/env python3
"""Reject statically detectable unsafe shader math."""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SHADERS = sorted((ROOT / "Sources").rglob("*.metal"))
SMOOTHSTEP = re.compile(
    r"smoothstep\(\s*([+-]?(?:\d+(?:\.\d*)?|\.\d+))\s*,"
    r"\s*([+-]?(?:\d+(?:\.\d*)?|\.\d+))\s*,"
)


def main() -> None:
    if not SHADERS:
        print("Shader safety check failed: no Metal files found.", file=sys.stderr)
        raise SystemExit(1)

    failures: list[str] = []
    for shader in SHADERS:
        for line_number, line in enumerate(shader.read_text().splitlines(), start=1):
            for match in SMOOTHSTEP.finditer(line):
                edge0 = float(match.group(1))
                edge1 = float(match.group(2))
                if edge0 >= edge1:
                    failures.append(
                        f"{shader.relative_to(ROOT)}:{line_number}: "
                        f"smoothstep edge0 ({edge0:g}) must be below edge1 ({edge1:g})"
                    )

    if failures:
        print("Shader safety check failed:", file=sys.stderr)
        for failure in failures:
            print(f"  {failure}", file=sys.stderr)
        raise SystemExit(1)

    print(f"Shader safety checks passed for {len(SHADERS)} Metal files.")


if __name__ == "__main__":
    main()
