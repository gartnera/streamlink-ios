# Streamlink for iOS — build orchestration.
#
#   make project     generate Streamlink.xcodeproj (needs: brew install xcodegen)
#   make build       build for the iOS Simulator
#   make run         boot a simulator, install, and launch the app
#   make smoke       headless resolve test against a public HLS stream
#   make ui-driver   interactive XCUITest UI driver on :8766 (ui-driver-device: on a device)
#   make mac         ad-hoc signed Mac Catalyst Release build, zipped for any Mac
#
# Override the simulator with:  make run SIM="iPhone 17 Pro"

SIM     ?= iPhone 17
SCHEME  ?= Streamlink
PROJECT ?= Streamlink.xcodeproj
BUNDLE  ?= com.agartner.streamlink
DERIVED ?= build
SMOKE_URL ?= hls://https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8

.PHONY: all project build run smoke ui-driver ui-driver-device mac clean distclean

all: project build

project:
	xcodegen generate

build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	  -configuration Debug -sdk iphonesimulator \
	  -destination 'platform=iOS Simulator,name=$(SIM)' \
	  -derivedDataPath $(DERIVED) \
	  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO AD_HOC_CODE_SIGNING_ALLOWED=YES \
	  build

run: build
	./scripts/run-sim.sh "$(SIM)" "$(BUNDLE)" "$(DERIVED)"

smoke: build
	./scripts/run-sim.sh "$(SIM)" "$(BUNDLE)" "$(DERIVED)" "$(SMOKE_URL)"

# Interactive UI driver on :8766 (see UIDriver/UIDriver.swift). Runs until
# POST /shutdown, so start it in the background.
ui-driver:
	xcodebuild test -project $(PROJECT) -scheme StreamlinkUIDriver \
	  -destination 'platform=iOS Simulator,name=$(SIM)' -derivedDataPath $(DERIVED) \
	  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO AD_HOC_CODE_SIGNING_ALLOWED=YES

# On a device: make ui-driver-device DEVID=<udid> TEAM=<team>, then send the
# printed token as X-Driver-Token to the printed URL (the CoreDevice tunnel
# address, which works over Wi-Fi; <device>.coredevice.local adds a 5 s lookup).
ifndef UIDRIVER_TOKEN
UIDRIVER_TOKEN := $(shell openssl rand -hex 16)
endif
ui-driver-device:
	@mkdir -p $(DERIVED) && xcrun devicectl device info details --device $(DEVID) \
	  --json-output $(DERIVED)/device.json >/dev/null 2>&1; \
	  echo "UIDRIVER=http://[$$(grep -o '"tunnelIPAddress" : "[^"]*' $(DERIVED)/device.json | cut -d'"' -f4)]:8766"
	@echo "UIDRIVER_TOKEN=$(UIDRIVER_TOKEN)"
	TEST_RUNNER_UIDRIVER_TOKEN=$(UIDRIVER_TOKEN) xcodebuild test -project $(PROJECT) -scheme StreamlinkUIDriver \
	  -destination "id=$(DEVID)" -derivedDataPath $(DERIVED) \
	  DEVELOPMENT_TEAM=$(TEAM) -allowProvisioningUpdates

# Mac Catalyst app from catalyst.yml. The iOS app on a Mac ("Designed for iPad")
# only launches on Macs in the signing profile; this one is ad-hoc signed and
# universal, so it runs on any Mac. The project goes under $(DERIVED) so the
# main one stays iOS-only; INFOPLIST_FILE is absolute because the plist
# path is relative to the project's directory.
MAC_APP = $(DERIVED)/catalyst/Build/Products/Release-maccatalyst/Streamlink.app
mac:
	mkdir -p $(DERIVED)/catalyst-project
	xcodegen generate --spec catalyst.yml --project $(DERIVED)/catalyst-project --project-root .
	xcodebuild -project $(DERIVED)/catalyst-project/$(PROJECT) -scheme $(SCHEME) \
	  -configuration Release -destination 'generic/platform=macOS,variant=Mac Catalyst' \
	  -derivedDataPath $(DERIVED)/catalyst \
	  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
	  INFOPLIST_FILE=$(CURDIR)/Generated/Info.plist \
	  build
	rm -f $(DERIVED)/Streamlink-mac.zip
	cd $(dir $(MAC_APP)) && zip -qry $(CURDIR)/$(DERIVED)/Streamlink-mac.zip Streamlink.app
	@echo "Zip: $(DERIVED)/Streamlink-mac.zip"

clean:
	rm -rf $(DERIVED)

distclean: clean
	rm -rf $(PROJECT) Generated
