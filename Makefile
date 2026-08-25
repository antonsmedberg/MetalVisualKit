# MetalVisualKit development commands
#
#   make help          show available commands
#   make open          open the development workspace
#   make package       open the standalone Swift package
#
#   make format        format Swift source code
#   make format-check  verify canonical Swift formatting
#   make lint          run SwiftLint
#   make diff-check    check Git whitespace
#
#   make build         build MetalVisualKit
#   make test          run the test suite
#   make swift6        run the strict Swift 6 compiler gate
#   make parity        validate repository and shader invariants
#   make demo          build the demo application
#   make verify        run the complete pre-push gate
#
#   make project       regenerate the XcodeGen demo project
#   make docs          build DocC
#   make icon          regenerate the example icon
#   make gif           create a README-sized GIF
#   make clean         remove generated build artefacts

SHELL := /bin/bash

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

SCHEME ?= MetalVisualKit
DEMO_SCHEME ?= MetalVisualKitDemo

WORKSPACE := Examples/MetalVisualKit.xcworkspace
DEMO_PROJECT_DIR := Examples/MetalVisualKitDemo
DEMO_PROJECT_YML := $(DEMO_PROJECT_DIR)/project.yml

DERIVED_DATA ?= .build/DerivedData
DOCS_DERIVED_DATA ?= .build/docs

DESTINATION ?= $(shell python3 Scripts/select-ios-simulator.py 2>/dev/null || \
	echo 'generic/platform=iOS Simulator')

SWIFT_PATHS := Sources Tests

XCODEBUILD ?= xcodebuild
PYTHON ?= python3
SWIFTLINT ?= swiftlint
SWIFTFORMAT ?= xcrun swift-format
XCODEGEN ?= xcodegen

.PHONY: \
	all \
	help \
	open \
	package \
	demo-open \
	demo-run \
	tools \
	config-check \
	format \
	format-check \
	diff-check \
	lint \
	style \
	build \
	test \
	swift6 \
	parity \
	demo \
	verify \
	project \
	docs \
	icon \
	gif \
	clean

.NOTPARALLEL: verify

# ---------------------------------------------------------------------------
# Default
# ---------------------------------------------------------------------------

all: verify

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------

help:
	@echo "MetalVisualKit development commands"
	@echo
	@echo "Development:"
	@echo "  make open          Open development workspace"
	@echo "  make package       Open standalone Swift package"
	@echo "  make demo-open     Open demo workspace"
	@echo
	@echo "Style:"
	@echo "  make format        Format Swift sources"
	@echo "  make format-check  Verify Swift formatting"
	@echo "  make lint          Run SwiftLint"
	@echo "  make style         Run read-only style checks"
	@echo
	@echo "Build:"
	@echo "  make build         Build package"
	@echo "  make test          Run tests"
	@echo "  make swift6        Strict Swift 6 build"
	@echo "  make demo          Build example app"
	@echo "  make parity        Run repository checks"
	@echo
	@echo "Quality:"
	@echo "  make verify        Complete pre-push gate"

# ---------------------------------------------------------------------------
# Development
# ---------------------------------------------------------------------------

open:
	@echo "Opening MetalVisualKit development workspace..."
	@xed "$(WORKSPACE)"

package:
	@echo "Opening standalone MetalVisualKit package..."
	@xed .

demo-open:
	@echo "Opening MetalVisualKit demo workspace..."
	@xed "$(WORKSPACE)"

demo-run: demo-open

# ---------------------------------------------------------------------------
# Toolchain
# ---------------------------------------------------------------------------

tools:
	@echo "Xcode:"
	@$(XCODEBUILD) -version
	@echo
	@echo "Swift:"
	@swift --version
	@echo
	@echo "SwiftLint:"
	@$(SWIFTLINT) version
	@echo
	@echo "swift-format:"
	@$(SWIFTFORMAT) --version
	@echo
	@echo "XcodeGen:"
	@$(XCODEGEN) --version

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

config-check:
	@echo "Checking repository configuration..."
	@test -f .editorconfig
	@test -f .swift-format
	@test -f .swiftlint.yml
	@test -f Package.swift
	@test -f "$(DEMO_PROJECT_YML)"
	@grep -qF '.swiftLanguageMode(.v6)' Package.swift
	@! grep -qF '.swiftLanguageMode(.v5)' Package.swift
	@grep -q 'SWIFT_VERSION: "6.0"' "$(DEMO_PROJECT_YML)"
	@echo "Repository configuration is valid."

# ---------------------------------------------------------------------------
# Formatting
# ---------------------------------------------------------------------------

format:
	@echo "Formatting Swift sources..."
	$(SWIFTFORMAT) format \
		--in-place \
		--recursive \
		$(SWIFT_PATHS)

format-check:
	@echo "Checking Swift formatting..."
	$(SWIFTFORMAT) lint \
		--strict \
		--recursive \
		$(SWIFT_PATHS)

diff-check:
	@echo "Checking Git whitespace..."
	@git diff --check
	@git diff --cached --check

style: diff-check format-check lint

# ---------------------------------------------------------------------------
# Lint
# ---------------------------------------------------------------------------

lint:
	@echo "Running SwiftLint..."
	$(SWIFTLINT) lint \
		--strict \
		--config .swiftlint.yml

# ---------------------------------------------------------------------------
# Build & test
# ---------------------------------------------------------------------------

build:
	@echo "Building MetalVisualKit..."
	$(XCODEBUILD) build \
		-scheme "$(SCHEME)" \
		-destination "$(DESTINATION)" \
		-derivedDataPath "$(DERIVED_DATA)" \
		CODE_SIGNING_ALLOWED=NO \
		-quiet

test:
	@echo "Testing MetalVisualKit..."
	$(XCODEBUILD) test \
		-scheme "$(SCHEME)" \
		-destination "$(DESTINATION)" \
		-derivedDataPath "$(DERIVED_DATA)" \
		CODE_SIGNING_ALLOWED=NO \
		-quiet

swift6:
	@echo "Checking Swift 6 strict concurrency..."
	$(XCODEBUILD) build \
		-scheme "$(SCHEME)" \
		-destination "$(DESTINATION)" \
		-derivedDataPath "$(DERIVED_DATA)" \
		SWIFT_STRICT_CONCURRENCY=complete \
		SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
		CODE_SIGNING_ALLOWED=NO \
		-quiet

# ---------------------------------------------------------------------------
# Repository validation
# ---------------------------------------------------------------------------

parity:
	@echo "Checking repository parity..."
	$(PYTHON) Scripts/check-struct-parity.py
	$(PYTHON) Scripts/check-shader-safety.py
	$(PYTHON) Scripts/check-media.py
	$(PYTHON) Scripts/test-media-check.py
	$(PYTHON) Scripts/test-simulator-selection.py
	$(PYTHON) Scripts/check-xcode-integration.py

# ---------------------------------------------------------------------------
# Demo
# ---------------------------------------------------------------------------

demo:
	@echo "Building MetalVisualKitDemo..."
	$(XCODEBUILD) build \
		-workspace "$(WORKSPACE)" \
		-scheme "$(DEMO_SCHEME)" \
		-destination "$(DESTINATION)" \
		-derivedDataPath "$(DERIVED_DATA)" \
		CODE_SIGNING_ALLOWED=NO \
		-quiet

# ---------------------------------------------------------------------------
# Complete quality gate
# ---------------------------------------------------------------------------

verify: \
	config-check \
	diff-check \
	format-check \
	lint \
	parity \
	build \
	test \
	swift6 \
	demo
	@echo
	@echo "MetalVisualKit verification passed."

# ---------------------------------------------------------------------------
# Project generation
# ---------------------------------------------------------------------------

project:
	@echo "Regenerating MetalVisualKitDemo project..."
	cd "$(DEMO_PROJECT_DIR)" && $(XCODEGEN) generate

# ---------------------------------------------------------------------------
# Documentation
# ---------------------------------------------------------------------------

docs:
	@echo "Building DocC documentation..."
	$(XCODEBUILD) docbuild \
		-scheme "$(SCHEME)" \
		-destination "$(DESTINATION)" \
		-derivedDataPath "$(DOCS_DERIVED_DATA)" \
		CODE_SIGNING_ALLOWED=NO

# ---------------------------------------------------------------------------
# Assets
# ---------------------------------------------------------------------------

icon:
	@echo "Generating example app icon..."
	swift Scripts/generate-app-icon.swift

# Usage:
#   make gif IN=recording.mov OUT=Media/particle-loader.gif

gif:
	@test -n "$(IN)" || \
		(echo "usage: make gif IN=recording.mov OUT=Media/out.gif" && exit 1)
	@test -n "$(OUT)" || \
		(echo "usage: make gif IN=recording.mov OUT=Media/out.gif" && exit 1)
	ffmpeg \
		-y \
		-i "$(IN)" \
		-vf "fps=15,scale=600:-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse" \
		-loop 0 \
		"$(OUT)"
	@ls -lh "$(OUT)"

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

clean:
	@echo "Removing local build artefacts..."
	rm -rf .build DerivedData
