#!/usr/bin/env python3
"""Validate committed README media and the example-app icon contract."""

from __future__ import annotations

import json
import struct
import zlib
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCREENSHOT = ROOT / "Media" / "loader-simulator.png"
ICON = (
    ROOT
    / "Examples"
    / "MetalVisualKitDemo"
    / "Resources"
    / "Assets.xcassets"
    / "AppIcon.appiconset"
    / "AppIcon-1024.png"
)
CONTENTS = ICON.with_name("Contents.json")
GENERATOR = ROOT / "Scripts" / "generate-app-icon.swift"

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
PNG_RGB = 2
PNG_RGBA = 6
MAX_PIXELS = 20_000_000


@dataclass(frozen=True)
class PNGInfo:
    width: int
    height: int
    bit_depth: int
    colour_type: int
    chunk_types: frozenset[bytes]

    @property
    def descriptor(self) -> tuple[int, int, int, int]:
        return self.width, self.height, self.bit_depth, self.colour_type

    @property
    def is_opaque_rgb(self) -> bool:
        return self.colour_type == PNG_RGB and b"tRNS" not in self.chunk_types


def display_path(path: Path) -> str:
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


def png_info(path: Path) -> PNGInfo:
    data = path.read_bytes()
    label = display_path(path)
    require(data.startswith(PNG_SIGNATURE), f"{label} has an invalid PNG signature")

    cursor = len(PNG_SIGNATURE)
    chunks: list[bytes] = []
    image_data = bytearray()
    header: tuple[int, int, int, int] | None = None
    saw_end = False

    while cursor < len(data):
        require(len(data) - cursor >= 12, f"{label} has a truncated PNG chunk")
        length = struct.unpack(">I", data[cursor : cursor + 4])[0]
        chunk_type = data[cursor + 4 : cursor + 8]
        payload_start = cursor + 8
        payload_end = payload_start + length
        chunk_end = payload_end + 4
        require(chunk_end <= len(data), f"{label} has truncated {chunk_type!r} data")

        payload = data[payload_start:payload_end]
        expected_crc = struct.unpack(">I", data[payload_end:chunk_end])[0]
        actual_crc = zlib.crc32(chunk_type + payload) & 0xFFFF_FFFF
        require(actual_crc == expected_crc, f"{label} has an invalid {chunk_type!r} CRC")

        require(bool(chunks) or chunk_type == b"IHDR", f"{label} does not start with IHDR")
        if chunk_type == b"IHDR":
            require(header is None and length == 13, f"{label} has an invalid IHDR")
            width, height, bit_depth, colour_type, compression, filtering, interlace = struct.unpack(
                ">IIBBBBB", payload
            )
            require(width > 0 and height > 0, f"{label} has invalid dimensions")
            require(width * height <= MAX_PIXELS, f"{label} exceeds the media pixel limit")
            require(
                compression == filtering == interlace == 0,
                f"{label} uses an unsupported PNG encoding",
            )
            header = width, height, bit_depth, colour_type
        elif chunk_type == b"IDAT":
            image_data.extend(payload)
        elif chunk_type == b"IEND":
            require(length == 0, f"{label} has a non-empty IEND chunk")
            saw_end = True

        chunks.append(chunk_type)
        cursor = chunk_end
        if saw_end:
            break

    require(saw_end and cursor == len(data), f"{label} is missing IEND or has trailing data")
    require(header is not None and bool(image_data), f"{label} is missing image data")
    assert header is not None

    width, height, bit_depth, colour_type = header
    require(bit_depth == 8, f"{label} must use 8-bit channels")
    channels = {PNG_RGB: 3, PNG_RGBA: 4}.get(colour_type)
    require(channels is not None, f"{label} uses unsupported colour type {colour_type}")
    assert channels is not None

    decompressor = zlib.decompressobj()
    decoded = decompressor.decompress(bytes(image_data)) + decompressor.flush()
    require(
        decompressor.eof and not decompressor.unused_data and not decompressor.unconsumed_tail,
        f"{label} has an incomplete or trailing zlib stream",
    )
    row_bytes = width * channels + 1
    require(len(decoded) == row_bytes * height, f"{label} has an invalid decoded image size")
    require(
        all(decoded[row * row_bytes] <= 4 for row in range(height)),
        f"{label} contains an invalid PNG row filter",
    )

    return PNGInfo(width, height, bit_depth, colour_type, frozenset(chunks))


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    screenshot = png_info(SCREENSHOT)
    require(
        screenshot.descriptor == (644, 1400, 8, PNG_RGBA),
        f"README screenshot must be 644×1400 8-bit RGBA; found {screenshot.descriptor}",
    )

    icon = png_info(ICON)
    require(
        icon.descriptor == (1024, 1024, 8, PNG_RGB) and icon.is_opaque_rgb,
        f"App icon must be an opaque 1024×1024 8-bit RGB PNG; found {icon.descriptor}",
    )

    contents = json.loads(CONTENTS.read_text(encoding="utf-8"))
    filenames = {image.get("filename") for image in contents.get("images", [])}
    require(ICON.name in filenames, "Asset catalogue does not reference AppIcon-1024.png")

    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    require(
        'src="Media/loader-simulator.png"' in readme,
        "README does not embed the verified simulator screenshot",
    )

    generator = GENERATOR.read_text(encoding="utf-8")
    require(
        str(ICON.relative_to(ROOT)) in generator,
        "Icon generator does not target the committed asset-catalogue icon",
    )

    media_notes = (ROOT / "Media" / "README.md").read_text(encoding="utf-8")
    require(
        "--demo-progress=0.68" in media_notes and "09:41" in media_notes,
        "Media notes do not document the deterministic screenshot state",
    )

    print("Media integrity checks passed for README screenshot and app icon.")


if __name__ == "__main__":
    main()
