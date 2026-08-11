#!/usr/bin/env python3
"""Validate the committed Xcode entry point for the package demo.

The demo project also exposes SwiftPM's library scheme. Without a committed
workspace and shared app scheme, Xcode can select the library scheme and report
that demo source files are not built by the active scheme. This check keeps the
single supported Xcode entry point explicit and reviewable.
"""

from __future__ import annotations

import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import NoReturn

ROOT = Path(__file__).resolve().parents[1]
WORKSPACE = (
    ROOT / "Examples" / "MetalVisualKit.xcworkspace" / "contents.xcworkspacedata"
)
PROJECT = ROOT / "Examples" / "MetalVisualKitDemo" / "MetalVisualKitDemo.xcodeproj"
PROJECT_FILE = PROJECT / "project.pbxproj"
SCHEME = PROJECT / "xcshareddata" / "xcschemes" / "MetalVisualKitDemo.xcscheme"
PROJECT_RELATIVE_PATH = "MetalVisualKitDemo/MetalVisualKitDemo.xcodeproj"
APP_TARGET = "MetalVisualKitDemo"
APP_PRODUCT = "MetalVisualKitDemo.app"
PROJECT_CONTAINER = "container:MetalVisualKitDemo.xcodeproj"
XCODE_VERSION = "2600"


def fail(message: str) -> NoReturn:
    print(f"Xcode integration error: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    if not WORKSPACE.is_file():
        fail(f"missing committed workspace: {WORKSPACE.relative_to(ROOT)}")

    workspace = ET.parse(WORKSPACE).getroot()
    locations = {
        location
        for element in workspace.iter("FileRef")
        if (location := element.attrib.get("location")) is not None
    }
    expected_location = f"group:{PROJECT_RELATIVE_PATH}"
    if locations != {expected_location}:
        fail(
            "workspace must reference only the demo project; "
            f"expected {expected_location!r}, found {sorted(locations)!r}"
        )

    if not PROJECT.is_dir():
        fail(f"missing committed demo project: {PROJECT.relative_to(ROOT)}")
    project_text = PROJECT_FILE.read_text()
    if f"LastUpgradeCheck = {XCODE_VERSION};" not in project_text:
        fail(f"demo project is not marked as upgraded by Xcode {XCODE_VERSION}")
    if "XCLocalSwiftPackageReference \"../..\"" not in project_text:
        fail("demo project does not declare the repository root as a local package")
    if "relativePath = ../..;" not in project_text:
        fail("demo project's local package path is not ../..")
    if not SCHEME.is_file():
        fail(f"missing shared demo scheme: {SCHEME.relative_to(ROOT)}")

    scheme = ET.parse(SCHEME).getroot()
    if scheme.attrib.get("LastUpgradeVersion") != XCODE_VERSION:
        fail(f"shared scheme is not marked for Xcode {XCODE_VERSION}")
    build_action = scheme.find("BuildAction")
    if build_action is None:
        fail("shared scheme has no BuildAction")
    buildable_references = list(build_action.iter("BuildableReference"))
    blueprint_names = {
        reference.attrib.get("BlueprintName") for reference in buildable_references
    }
    if APP_TARGET not in blueprint_names:
        fail(
            f"shared scheme BuildAction does not build {APP_TARGET!r}; "
            f"found {sorted(name for name in blueprint_names if name)!r}"
        )
    app_references = [
        reference
        for reference in buildable_references
        if reference.attrib.get("BlueprintName") == APP_TARGET
    ]
    if not any(
        reference.attrib.get("BuildableName") == APP_PRODUCT
        and reference.attrib.get("ReferencedContainer") == PROJECT_CONTAINER
        for reference in app_references
    ):
        fail("shared scheme BuildAction does not reference the committed demo app product")

    launch_action = scheme.find("LaunchAction")
    if launch_action is None or launch_action.attrib.get("buildConfiguration") != "Debug":
        fail("shared scheme must launch the Debug configuration")

    print("Xcode workspace and shared demo scheme are configured correctly.")


if __name__ == "__main__":
    main()
