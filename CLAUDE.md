# Development flow

Every change goes through these steps in order. Don't skip ahead.

1. **Build and test in the local Simulator.** Run the change in the Simulator
   and confirm it works; a successful compile isn't enough.
   - `make project` (after adding/removing files), then `make build`.
   - Headless check: `make smoke` and read the printed `smoke_result.json`.
     It defaults to Apple's public HLS test stream; use Apple HLS example URLs
     (`hls://https://devstreaming-cdn.apple.com/...`) for testing. Delete the
     old result first
     (`rm "$(xcrun simctl get_app_container booted com.agartner.streamlink data)/Documents/smoke_result.json"`),
     or the script may print a stale file from a previous run.
   - Chat webview: launch with `--debug-server` (Debug builds), then
     `curl -d '<js>' localhost:8765/eval` runs JS in the page and
     `curl localhost:8765/log` shows its console, plus a tap/focus/resize trace.
     On a device, launch with `devicectl ... process launch --console` to see it.
   - When adding behavior, extend the smoke test in `ContentView.maybeRunSmokeTest`
     to record something that proves it works.
   - Don't drive the Simulator with synthetic mouse clicks; it takes over the
     user's cursor.
2. **Run `/code-review`** on the working-tree changes, only after the Simulator
   test passes. Fix the findings, then repeat step 1 to re-test the fixes.
3. **Deploy to the device and/or commit**, only after steps 1 and 2. Never commit
   or deploy code that hasn't been tested in the Simulator and reviewed.

## Device deploy

`project.yml` keeps `DEVELOPMENT_TEAM: ""` on purpose so anyone can sideload.
Pass your team on the command line (`DEVELOPMENT_TEAM=<team>`) and never commit it:

```
xcodebuild -project Streamlink.xcodeproj -scheme Streamlink -configuration Debug \
  -sdk iphoneos -destination "id=$DEVID" -derivedDataPath build \
  DEVELOPMENT_TEAM=<team> -allowProvisioningUpdates build
xcrun devicectl device install app --device "$DEVID" build/Build/Products/Debug-iphoneos/Streamlink.app
xcrun devicectl device process launch --device "$DEVID" com.agartner.streamlink
```
