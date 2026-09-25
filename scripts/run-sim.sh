#!/usr/bin/env bash
# Boot a simulator, install the built app, and launch it.
# Usage: run-sim.sh <SIM_NAME> <BUNDLE_ID> <DERIVED_DIR> [SMOKE_URL]
set -euo pipefail

SIM_NAME="${1:?simulator name}"
BUNDLE="${2:?bundle id}"
DERIVED="${3:?derived data dir}"
SMOKE_URL="${4:-}"

APP="$DERIVED/Build/Products/Debug-iphonesimulator/Streamlink.app"
[ -d "$APP" ] || { echo "App not found at $APP (run 'make build')" >&2; exit 1; }

log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }

# Resolve a device UDID for the requested name.
UDID="$(xcrun simctl list devices available | awk -v n="$SIM_NAME" -F'[()]' '
  $0 ~ n" \\(" { print $2; exit }')"
[ -n "$UDID" ] || { echo "No available simulator named '$SIM_NAME'" >&2; exit 1; }
log "Simulator: $SIM_NAME ($UDID)"

STATE="$(xcrun simctl list devices | grep "$UDID" | grep -o '(Booted)' || true)"
if [ -z "$STATE" ]; then
  log "Booting…"
  xcrun simctl boot "$UDID" || true
  xcrun simctl bootstatus "$UDID" -b || true
fi

log "Installing app"
xcrun simctl install "$UDID" "$APP"

if [ -n "$SMOKE_URL" ]; then
  log "Launching in smoke mode: $SMOKE_URL"
  xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE" --smoke-url "$SMOKE_URL" || true
  CONTAINER="$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data)"
  RESULT="$CONTAINER/Documents/smoke_result.json"
  log "Waiting for smoke result at $RESULT"
  for _ in $(seq 1 60); do
    if [ -f "$RESULT" ]; then
      echo "----- smoke_result.json -----"
      cat "$RESULT"
      echo
      echo "-----------------------------"
      exit 0
    fi
    sleep 1
  done
  echo "Timed out waiting for smoke result." >&2
  exit 2
else
  log "Launching"
  xcrun simctl launch --terminate-running-process --console-pty "$UDID" "$BUNDLE"
fi
