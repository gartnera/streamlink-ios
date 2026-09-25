# Streamlink for iOS — build orchestration.
#
#   make wheels      cross-compile lxml + pycryptodome iOS wheels (once)
#   make bootstrap   fetch Python runtime + assemble on-device packages
#   make project     generate Streamlink.xcodeproj (needs: brew install xcodegen)
#   make build       build for the iOS Simulator
#   make run         boot a simulator, install, and launch the app
#   make smoke       headless resolve test against a public HLS stream
#
# Override the simulator with:  make run SIM="iPhone 17 Pro"

SIM     ?= iPhone 17
SCHEME  ?= Streamlink
PROJECT ?= Streamlink.xcodeproj
BUNDLE  ?= com.example.streamlink
DERIVED ?= build
SMOKE_URL ?= hls://https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8

.PHONY: all bootstrap project build run smoke wheels clean distclean

all: bootstrap project build

wheels:
	./scripts/build-wheels.sh

bootstrap:
	./scripts/bootstrap.sh

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

clean:
	rm -rf $(DERIVED)

distclean: clean
	rm -rf Python.xcframework app_packages native $(PROJECT) Generated .build-tmp
