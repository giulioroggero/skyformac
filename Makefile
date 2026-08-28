PROJECT      := skyformac.xcodeproj
SCHEME       := skyformac
CONFIGURATION := Debug
DESTINATION  := platform=macOS
DERIVED_DATA := build
APP_PATH     := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/skyformac.app

.PHONY: all build test run clean open lipo-check release help

all: build

## Build the app (Debug config) into ./build/
build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIGURATION) \
		-destination '$(DESTINATION)' -derivedDataPath $(DERIVED_DATA) build

## Run the unit test suite (skyformacTests). -retry-tests-on-failure is a buffer against
## transient CI contention (GPU tests racing the runner's other load, disk I/O hiccups, etc.) —
## see the `.serialized` traits on the Metal-dispatching test suites for the actual fix to GPU
## test flakiness specifically; this just catches whatever that doesn't.
test:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-destination '$(DESTINATION)' -derivedDataPath $(DERIVED_DATA) \
		-retry-tests-on-failure test

## Build (if needed) and launch the app locally
run: build
	open "$(APP_PATH)"

## Remove local build artifacts
clean:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(DERIVED_DATA) clean
	rm -rf $(DERIVED_DATA)

## Open the project in Xcode
open:
	open $(PROJECT)

## Sanity-check the vendored ZWO dylib is a universal (arm64 + x86_64) binary
lipo-check:
	lipo -info Vendor/ZWO/lib/libASICamera2.dylib

## Build, Developer-ID-sign, and notarize a distributable .dmg — see docs/distribution.md
## for the one-time setup (Developer ID certificate, notarytool credentials) this
## requires; needs SKYFORMAC_TEAM_ID set.
release:
	./scripts/release.sh

help:
	@echo "Targets:"
	@echo "  make build        - build the app into ./build"
	@echo "  make test         - run the skyformacTests unit test suite"
	@echo "  make run          - build and launch skyformac.app"
	@echo "  make clean        - remove build artifacts"
	@echo "  make open         - open the project in Xcode"
	@echo "  make lipo-check   - verify the vendored dylib has both arm64 and x86_64 slices"
	@echo "  make release      - build/sign/notarize a distributable .dmg (see docs/distribution.md)"
