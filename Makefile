# MetalVisualKit
#
#   make build     build the package for the iOS simulator
#   make test      run the pipeline, layout and projection tests
#   make parity    check the Swift <-> MSL uniform struct layouts
#   make demo      build the committed example app project
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
	python3 Scripts/test-simulator-selection.py

demo:
	xcodebuild build \
		-project Examples/MetalVisualKitDemo/MetalVisualKitDemo.xcodeproj \
		-scheme MetalVisualKitDemo -destination "$(DESTINATION)" -quiet

project:
	cd Examples/MetalVisualKitDemo && xcodegen generate

lint:
	swiftlint lint --strict

# Non-blocking: lists the data-race diagnostics blocking Swift 6 language mode.
# The manifest's swiftLanguageMode overrides the xcodebuild SWIFT_VERSION flag,
# so the flag alone measures nothing. Patch the manifest, build, always restore
# it — the trap runs even when the build fails or you interrupt it.
swift6:
	@cp Package.swift Package.swift.bak
	@trap 'mv Package.swift.bak Package.swift' EXIT INT TERM; \
	sed -i '' 's/\.swiftLanguageMode(\.v5)/.swiftLanguageMode(.v6)/g' Package.swift; \
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
