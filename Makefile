DERIVED := build/DerivedData
XCB := xcodebuild -workspace TacitType.xcworkspace -derivedDataPath $(DERIVED) CODE_SIGNING_ALLOWED=NO

.PHONY: generate open run run-signed run-ios build build-mac build-ios test test-swift test-python ml-env clean

generate:
	xcodegen generate --use-cache

open: generate
	open TacitType.xcworkspace

# Ad-hoc signed Debug build, launched from build/. Relaunches if already running.
run: generate
	$(XCB) -scheme TacitType-macOS -configuration Debug -destination 'platform=macOS,arch=arm64' \
		CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build
	-pkill -x TacitType
	open $(DERIVED)/Build/Products/Debug/TacitType.app

# Debug build signed with your team from Config/Signing.local.xcconfig. macOS ties the Accessibility
# grant to the signature, so dictation keeps its permission across rebuilds. `make run` signs ad hoc,
# which makes macOS forget the grant every build.
run-signed: generate
	$(XCB) -scheme TacitType-macOS -configuration Debug -destination 'platform=macOS,arch=arm64' \
		CODE_SIGNING_ALLOWED=YES -allowProvisioningUpdates build
	-pkill -x TacitType
	open $(DERIVED)/Build/Products/Debug/TacitType.app

# Signed Debug build installed and launched on the connected iPhone.
# Needs Config/Signing.local.xcconfig with your team.
IOS_DEVICE ?= $(shell xcrun devicectl list devices 2>/dev/null | awk '/connected/ {for (i = 1; i <= NF; i++) if ($$i ~ /^[0-9A-F]{8}-[0-9A-F]{4}-/) {print $$i; exit}}')

run-ios: generate
	@test -n "$(IOS_DEVICE)" || { echo "No connected iPhone. Plug it in, unlock it and try again."; exit 1; }
	xcodebuild -workspace TacitType.xcworkspace -derivedDataPath $(DERIVED) -scheme TacitType-iOS \
		-configuration Debug -destination 'generic/platform=iOS' -allowProvisioningUpdates build
	xcrun devicectl device install app --device $(IOS_DEVICE) $(DERIVED)/Build/Products/Debug-iphoneos/TacitType.app
	xcrun devicectl device process launch --device $(IOS_DEVICE) com.tacittype.ios

build: build-mac build-ios

build-mac: generate
	$(XCB) -scheme TacitType-macOS -destination 'generic/platform=macOS' build

build-ios: generate
	$(XCB) -scheme TacitType-iOS -destination 'generic/platform=iOS Simulator' build

test: test-swift test-python

test-swift:
	swift test --package-path Packages/TacitKit

ml-env:
	python3 -m venv ml/.venv
	ml/.venv/bin/pip install -e 'ml[dev]'

test-python:
	cd ml && .venv/bin/pytest

clean:
	rm -rf build Packages/TacitKit/.build TacitType.xcodeproj
