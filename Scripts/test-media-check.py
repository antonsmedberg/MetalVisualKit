#!/usr/bin/env python3
"""Regression tests for the standard-library PNG media validator."""

from __future__ import annotations

import importlib.util
import struct
import sys
import tempfile
import unittest
import zlib
from pathlib import Path

SCRIPT = Path(__file__).with_name("check-media.py")
SPEC = importlib.util.spec_from_file_location("check_media", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("Unable to load check-media.py")
check_media = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = check_media
SPEC.loader.exec_module(check_media)


class MediaCheckTests(unittest.TestCase):
    def temporary_png(self, data: bytes) -> Path:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        path = Path(directory.name) / "fixture.png"
        path.write_bytes(data)
        return path

    def test_committed_media_is_complete(self) -> None:
        screenshot = check_media.png_info(check_media.SCREENSHOT)
        icon = check_media.png_info(check_media.ICON)
        self.assertEqual(screenshot.descriptor, (644, 1400, 8, check_media.PNG_RGBA))
        self.assertEqual(icon.descriptor, (1024, 1024, 8, check_media.PNG_RGB))
        self.assertTrue(icon.is_opaque_rgb)

    def test_truncated_png_is_rejected(self) -> None:
        path = self.temporary_png(check_media.SCREENSHOT.read_bytes()[:26])
        with self.assertRaisesRegex(AssertionError, "truncated"):
            check_media.png_info(path)

    def test_bad_chunk_crc_is_rejected(self) -> None:
        damaged = bytearray(check_media.SCREENSHOT.read_bytes())
        damaged[20] ^= 0x01
        path = self.temporary_png(bytes(damaged))
        with self.assertRaisesRegex(AssertionError, "CRC"):
            check_media.png_info(path)

    def test_trailing_data_is_rejected(self) -> None:
        path = self.temporary_png(check_media.SCREENSHOT.read_bytes() + b"unexpected")
        with self.assertRaisesRegex(AssertionError, "trailing"):
            check_media.png_info(path)

    def test_rgb_transparency_chunk_is_not_opaque(self) -> None:
        source = check_media.ICON.read_bytes()
        ihdr_end = len(check_media.PNG_SIGNATURE) + 4 + 4 + 13 + 4
        chunk_type = b"tRNS"
        payload = b"\x00\x00\x00\x00\x00\x00"
        chunk = (
            struct.pack(">I", len(payload))
            + chunk_type
            + payload
            + struct.pack(">I", zlib.crc32(chunk_type + payload) & 0xFFFF_FFFF)
        )
        path = self.temporary_png(source[:ihdr_end] + chunk + source[ihdr_end:])
        self.assertFalse(check_media.png_info(path).is_opaque_rgb)


if __name__ == "__main__":
    unittest.main(verbosity=2)
