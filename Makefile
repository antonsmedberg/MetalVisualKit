# MetalVisualKit
#
#   make build     build the package for the iOS simulator
#   make test      run pipeline, layout, lifecycle, projection and compute tests
#   make parity    check layouts, simulator selection and Xcode integration
#   make demo      build the committed example app workspace
#   make project   regenerate the example app project with XcodeGen
#   make lint      run SwiftLint
#   make docs      build the DocC archive
#   make gif       convert a screen recording to a README-sized GIF
#   make clean     remove build artefacts

# Resolved from whatever simulators are actually installed. Override with:
#   make build DESTINATION='platform=iOS Simulator,name=iPhone 17 Pro'
DESTINATION ?= $(shell python3 Scripts/select-ios-simulator.py 2>/dev/null || \
	echo 'generic/platform=iOS Simulator')
SCHEME      ?= MetalVisualKit

.PHONY: all build test parity demo project lint swift6 docs gif clean

all: parity build test

build:
	xcodebuild build -scheme "$(SCHEME)" -destination "$(DESTINATION)" -quiet

test:
	xcodebuild test -scheme "$(SCHEME)" -destination "$(DESTINATION)" -quiet

parity:
	python3 Scripts/check-struct-parity.py
	python3 Scripts/check-shader-safety.py
	python3 Scripts/test-simulator-selection.py
	python3 Scripts/check-xcode-integration.py

demo:
	xcodebuild build \
		-workspace Examples/MetalVisualKit.xcworkspace \
		-scheme MetalVisualKitDemo -destination "$(DESTINATION)" -quiet

project:
	cd Examples/MetalVisualKitDemo && xcodegen generate

lint:
	swiftlint lint --strict

# Non-blocking: lists the data-race diagnostics blocking Swift 6 language mode.
# Build a disposable copy because the manifest's swiftLanguageMode overrides the
# xcodebuild SWIFT_VERSION flag. The working manifest is never edited, which also
# avoids Xcode creating conflict copies while the package is open.
swift6:
	@set -e; tmp=$$(mktemp -d); \
	trap 'rm -rf "$$tmp"' EXIT INT TERM; \
	rsync -a --exclude .git --exclude .build --exclude DerivedData ./ "$$tmp/"; \
	sed -i '' 's/\.swiftLanguageMode(\.v5)/.swiftLanguageMode(.v6)/g' "$$tmp/Package.swift"; \
	! grep -qF '.swiftLanguageMode(.v5)' "$$tmp/Package.swift"; \
	grep -qF '.swiftLanguageMode(.v6)' "$$tmp/Package.swift"; \
	cd "$$tmp"; \
	xcodebuild build -scheme "$(SCHEME)" -destination "$(DESTINATION)" \
		SWIFT_STRICT_CONCURRENCY=complete

docs:
	xcodebuild docbuild -scheme "$(SCHEME)" -destination "$(DESTINATION)" \
		-derivedDataPath .build/docs CODE_SIGNING_ALLOWED=NO

# usage: make gif IN=recording.mov OUT=Media/particle-loader.gif
gif:
	@test -n "$(IN)" || (echo "usage: make gif IN=recording.mov OUT=Media/out.gif" && exit 1)
	ffmpeg -i "$(IN)" -vf "fps=15,scale=600:-1:flags=lanczos,split[a][b];\
	[a]palettegen[p];[b][p]paletteuse" -loop 0 "$(OUT)"
	@ls -lh "$(OUT)"

clean:
	rm -rf .build DerivedData
